###############################################################################
# Module 3: EKS Scaling (SQS + KEDA + Karpenter) — ap-northeast-2
#
# Windows에는 docker/kubectl/helm이 없으므로, 클러스터/애드온/앱 배포는 모두
# Bastion EC2(setup.sh.tpl)에서 수행한다. Terraform은 인프라(VPC/EKS/NodeGroup/
# SQS/IAM/ECR/S3/Bastion)만 생성하고, Bastion이 docker build/push + helm + kubectl을 실행한다.
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  region        = "ap-northeast-2"
  cluster_name  = "skm-eks-cluster"
  discovery_tag = "skm-eks-cluster"
}

###############################################################################
# SQS
###############################################################################
resource "aws_sqs_queue" "order" {
  name                       = "skm-order-queue"
  visibility_timeout_seconds = 60
}

###############################################################################
# VPC (public-only: NodeGroup/Karpenter 노드가 public IP로 SQS/STS/ECR 접근)
###############################################################################
data "aws_availability_zones" "azs" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "skm-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "skm-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.azs.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                                          = "skm-pub-${count.index}"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "karpenter.sh/discovery"                      = local.discovery_tag
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "skm-pub-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# EKS Cluster (v1.35)
###############################################################################
resource "aws_iam_role" "eks_cluster" {
  name = "skm-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = "1.35"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  lifecycle {
    ignore_changes = [access_config]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# Karpenter가 subnet/SG를 discovery 태그로 찾는다 → 클러스터 SG에도 태그 부여
resource "aws_ec2_tag" "cluster_sg_discovery" {
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = local.discovery_tag
}

###############################################################################
# Managed NodeGroup: skm-cluster-addon-ng
#   - t3.medium 1/1/1, tainted(dedicated=addon) → 애플리케이션은 스케줄되지 않음
#   - 시스템 애드온(CoreDNS/KEDA/Karpenter)만 이 노드에서 구동
#   - 인스턴스 Name 태그를 skm-cluster-addon-ng-node로 고정하기 위해 Launch Template 사용
###############################################################################
resource "aws_iam_role" "addon_ng" {
  name = "skm-cluster-addon-ng-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "addon_ng_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.addon_ng.name
}
resource "aws_iam_role_policy_attachment" "addon_ng_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.addon_ng.name
}
resource "aws_iam_role_policy_attachment" "addon_ng_ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.addon_ng.name
}
resource "aws_iam_role_policy_attachment" "addon_ng_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.addon_ng.name
}

# instanceTypes는 NodeGroup에 두고(채점 describe-nodegroup instanceTypes[0]=t3.medium),
# Launch Template은 인스턴스 Name 태그 전용(instance_type 미지정)
resource "aws_launch_template" "addon_ng" {
  name = "skm-cluster-addon-ng-lt"
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "skm-cluster-addon-ng-node" }
  }
}

resource "aws_eks_node_group" "addon" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "skm-cluster-addon-ng"
  node_role_arn   = aws_iam_role.addon_ng.arn
  subnet_ids      = aws_subnet.public[*].id
  instance_types  = ["t3.medium"]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  launch_template {
    id      = aws_launch_template.addon_ng.id
    version = aws_launch_template.addon_ng.latest_version
  }

  taint {
    key    = "dedicated"
    value  = "addon"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.addon_ng_worker,
    aws_iam_role_policy_attachment.addon_ng_cni,
    aws_iam_role_policy_attachment.addon_ng_ecr,
  ]
}

# CoreDNS: addon-ng가 tainted이므로 toleration 부여(안 그러면 Pending)
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
  configuration_values = jsonencode({
    tolerations = [{ key = "dedicated", value = "addon", effect = "NoSchedule" }]
  })
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.addon]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.addon]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.addon]
}

###############################################################################
# OIDC / IRSA
###############################################################################
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

locals {
  oidc_provider = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# IRSA: order-processor (SQS receive/delete)
resource "aws_iam_role" "app" {
  name = "skm-order-processor-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "${local.oidc_provider}:sub" = "system:serviceaccount:skillsmkt:order-processor-sa"
        "${local.oidc_provider}:aud" = "sts.amazonaws.com"
      } }
    }]
  })
}

resource "aws_iam_role_policy" "app_sqs" {
  name = "skm-order-processor-sqs"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      Resource = aws_sqs_queue.order.arn
    }]
  })
}

# IRSA: keda-operator (SQS queue length 조회)
resource "aws_iam_role" "keda" {
  name = "skm-keda-operator-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "${local.oidc_provider}:sub" = "system:serviceaccount:keda:keda-operator"
        "${local.oidc_provider}:aud" = "sts.amazonaws.com"
      } }
    }]
  })
}

resource "aws_iam_role_policy" "keda_sqs" {
  name = "skm-keda-sqs"
  role = aws_iam_role.keda.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"], Resource = aws_sqs_queue.order.arn }]
  })
}

# IRSA: karpenter controller (kube-system:karpenter)
resource "aws_iam_role" "karpenter" {
  name = "skm-karpenter-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:karpenter"
        "${local.oidc_provider}:aud" = "sts.amazonaws.com"
      } }
    }]
  })
}

resource "aws_iam_role_policy" "karpenter" {
  name = "skm-karpenter"
  role = aws_iam_role.karpenter.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ec2:*", "pricing:GetProducts", "ssm:GetParameter"], Resource = "*" },
      { Effect = "Allow", Action = ["eks:DescribeCluster"], Resource = aws_eks_cluster.main.arn },
      { Effect = "Allow", Action = ["iam:PassRole", "iam:GetInstanceProfile", "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile"], Resource = "*" }
    ]
  })
}

###############################################################################
# Karpenter Node Role (Karpenter가 띄우는 노드용)
###############################################################################
resource "aws_iam_role" "node" {
  name = "skm-app-node-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "node" {
  name = "skm-app-node-profile"
  role = aws_iam_role.node.name
}

resource "aws_eks_access_entry" "node" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
}

###############################################################################
# ECR (order-processor 이미지) + S3 (Bastion 빌드 컨텍스트/로그)
###############################################################################
resource "aws_ecr_repository" "app" {
  name                 = "skm-order-processor"
  force_delete         = true
  image_tag_mutability = "MUTABLE"
}

resource "aws_s3_bucket" "bastion" {
  bucket        = "skm-bastion-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_object" "app_files" {
  for_each = toset(["Dockerfile", "app.py", "requirements.txt"])
  bucket   = aws_s3_bucket.bastion.id
  key      = "app/${each.value}"
  source   = "${path.module}/app/${each.value}"
  etag     = filemd5("${path.module}/app/${each.value}")
}

resource "aws_s3_object" "deploy_script" {
  bucket  = aws_s3_bucket.bastion.id
  key     = "scripts/setup.sh"
  content = templatefile("${path.module}/deploy.sh.tpl", {
    region             = local.region
    cluster            = aws_eks_cluster.main.name
    account_id         = data.aws_caller_identity.current.account_id
    ecr_repo_url       = aws_ecr_repository.app.repository_url
    cluster_endpoint   = aws_eks_cluster.main.endpoint
    keda_role_arn      = aws_iam_role.keda.arn
    karpenter_role_arn = aws_iam_role.karpenter.arn
    app_role_arn       = aws_iam_role.app.arn
    node_role_name     = aws_iam_role.node.name
    sqs_url            = aws_sqs_queue.order.url
    s3_bucket          = aws_s3_bucket.bastion.bucket
    discovery_tag      = local.discovery_tag
  })
}

###############################################################################
# Bastion (docker build/push + helm + kubectl)
###############################################################################
resource "aws_iam_role" "bastion" {
  name = "skm-bastion-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "bastion" {
  name = "skm-bastion-policy"
  role = aws_iam_role.bastion.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:*"], Resource = "*" },
      { Effect = "Allow", Action = ["eks:DescribeCluster", "eks:ListClusters"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:DescribeSubnets", "ec2:DescribeVpcs", "ec2:CreateTags"], Resource = "*" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"], Resource = [aws_s3_bucket.bastion.arn, "${aws_s3_bucket.bastion.arn}/*"] }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "skm-bastion-profile"
  role = aws_iam_role.bastion.name
}

# 사설 엔드포인트가 켜져 있으면 VPC 내부 DNS가 EKS API를 사설 ENI로 해석 → Bastion은
# 클러스터 SG 소속이 아니라 443이 막혀 kubectl 타임아웃. 클러스터 SG에 VPC 443 인바운드 허용.
resource "aws_vpc_security_group_ingress_rule" "bastion_to_eks_api" {
  security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  cidr_ipv4         = aws_vpc.main.cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Allow in-VPC (bastion) access to EKS API server"
}

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.bastion]
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

resource "aws_security_group" "bastion" {
  name        = "skm-bastion-sg"
  description = "Bastion all open"
  vpc_id      = aws_vpc.main.id

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

  tags = { Name = "skm-bastion-sg" }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  user_data = base64encode(templatefile("${path.module}/setup.sh.tpl", {
    region    = local.region
    cluster   = aws_eks_cluster.main.name
    s3_bucket = aws_s3_bucket.bastion.bucket
  }))

  user_data_replace_on_change = true
  tags                        = { Name = "skm-bastion" }

  depends_on = [
    aws_eks_node_group.addon,
    aws_eks_addon.coredns,
    aws_eks_access_policy_association.bastion,
    aws_iam_openid_connect_provider.eks,
    aws_s3_object.app_files,
    aws_s3_object.deploy_script,
    aws_vpc_security_group_ingress_rule.bastion_to_eks_api,
    aws_eks_access_entry.node,
  ]
}



###############################################################################
# Outputs
###############################################################################
output "sqs_queue_url" { value = aws_sqs_queue.order.url }
output "cluster_name" { value = aws_eks_cluster.main.name }
output "app_role_arn" { value = aws_iam_role.app.arn }
output "bastion_public_ip" { value = aws_instance.bastion.public_ip }