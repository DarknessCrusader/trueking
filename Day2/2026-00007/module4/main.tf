terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

variable "competitor_number" {
  description = "선수등번호"
  type        = string
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "o11y-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "o11y-igw" }
}

resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true
  tags = {
    Name                                 = "o11y-pub-a"
    "kubernetes.io/cluster/o11y-cluster" = "shared"
    "kubernetes.io/role/elb"             = "1"
  }
}

resource "aws_subnet" "pub_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = true
  tags = {
    Name                                 = "o11y-pub-c"
    "kubernetes.io/cluster/o11y-cluster" = "shared"
    "kubernetes.io/role/elb"             = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "o11y-pub-rt" }
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.pub_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "pub_c" {
  subnet_id      = aws_subnet.pub_c.id
  route_table_id = aws_route_table.public.id
}

locals {
  subnet_ids = [aws_subnet.pub_a.id, aws_subnet.pub_c.id]
}

# ALB Security Group
resource "aws_security_group" "alb" {
  name   = "o11y-alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EKS Cluster Security Group
resource "aws_security_group" "eks" {
  name   = "o11y-eks-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# App ALB
resource "aws_lb" "app" {
  name               = "o11y-app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids
}

resource "aws_lb_target_group" "app" {
  name        = "o11y-app-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path = "/healthz"
    port = "8080"
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Grafana ALB
resource "aws_lb" "grafana" {
  name               = "o11y-grafana-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids
}

resource "aws_lb_target_group" "grafana" {
  name        = "o11y-grafana-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check {
    path = "/api/health"
    port = "3000"
  }
}

resource "aws_lb_listener" "grafana" {
  load_balancer_arn = aws_lb.grafana.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# S3 bucket for setup files
resource "aws_s3_bucket" "setup" {
  bucket        = "o11y-setup-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_object" "manifests" {
  for_each = fileset("${path.module}/manifest", "*")
  bucket   = aws_s3_bucket.setup.id
  key      = each.value
  source   = "${path.module}/manifest/${each.value}"
  etag     = filemd5("${path.module}/manifest/${each.value}")
}

# Bastion
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

resource "aws_iam_role" "bastion" {
  name = "o11y-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "o11y-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name   = "o11y-bastion-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.pub_a.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  user_data = <<-EOF
#!/bin/bash
echo 'ec2-user:Skill53##' | chpasswd
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd
yum install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user

# kubectl
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.33.0/2025-05-01/bin/linux/amd64/kubectl
chmod +x kubectl && mv kubectl /usr/bin/

# eksctl
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp && mv /tmp/eksctl /usr/bin/

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Download from S3
aws s3 cp s3://${aws_s3_bucket.setup.id}/ /home/ec2-user/ --recursive --region ap-northeast-1
chown -R ec2-user:ec2-user /home/ec2-user/
chmod +x /home/ec2-user/setup.sh

# Set competitor number for setup.sh
echo 'COMPETITOR_NUMBER=${var.competitor_number}' >> /etc/environment
echo 'export COMPETITOR_NUMBER=${var.competitor_number}' >> /home/ec2-user/.bashrc
sed -i '2i COMPETITOR_NUMBER=${var.competitor_number}' /home/ec2-user/setup.sh
EOF

  tags = { Name = "o11y-bastion" }

  depends_on = [aws_s3_object.manifests]
}

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"
  tags     = { Name = "o11y-bastion-eip" }
}

output "cluster_name" {
  value = "o11y-cluster"
}

output "bastion_public_ip" {
  value = aws_eip.bastion.public_ip
}

output "app_tg_arn" {
  value = aws_lb_target_group.app.arn
}

output "grafana_tg_arn" {
  value = aws_lb_target_group.grafana.arn
}
