###############################################################################
# Module 2: VPC Lattice (ap-northeast-1 Tokyo)
###############################################################################

data "aws_availability_zones" "tokyo" {
  state = "available"
}

data "aws_ami" "al2023_tokyo" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

data "aws_ec2_managed_prefix_list" "lattice" {
  name = "com.amazonaws.ap-northeast-1.vpc-lattice"
}

# VPCs
resource "aws_vpc" "m2_client" {
  cidr_block           = "10.61.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "skills-lattice-client-vpc" }
}

resource "aws_vpc" "m2_service" {
  cidr_block           = "10.62.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "skills-lattice-service-vpc" }
}

resource "aws_subnet" "m2_client" {
  vpc_id                  = aws_vpc.m2_client.id
  cidr_block              = "10.61.1.0/24"
  availability_zone       = data.aws_availability_zones.tokyo.names[0]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "m2_service" {
  vpc_id            = aws_vpc.m2_service.id
  cidr_block        = "10.62.1.0/24"
  availability_zone = data.aws_availability_zones.tokyo.names[0]
}

resource "aws_internet_gateway" "m2_client" {
  vpc_id = aws_vpc.m2_client.id
}

resource "aws_route_table" "m2_client" {
  vpc_id = aws_vpc.m2_client.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.m2_client.id
  }
}

resource "aws_route_table_association" "m2_client" {
  subnet_id      = aws_subnet.m2_client.id
  route_table_id = aws_route_table.m2_client.id
}

# Service VPC needs IGW for userdata
resource "aws_internet_gateway" "m2_service" {
  vpc_id = aws_vpc.m2_service.id
}

resource "aws_subnet" "m2_service_public" {
  vpc_id                  = aws_vpc.m2_service.id
  cidr_block              = "10.62.2.0/24"
  availability_zone       = data.aws_availability_zones.tokyo.names[0]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "m2_service" {
  vpc_id = aws_vpc.m2_service.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.m2_service.id
  }
}

resource "aws_route_table_association" "m2_service" {
  subnet_id      = aws_subnet.m2_service.id
  route_table_id = aws_route_table.m2_service.id
}

resource "aws_route_table_association" "m2_service_public" {
  subnet_id      = aws_subnet.m2_service_public.id
  route_table_id = aws_route_table.m2_service.id
}

# Security Groups
resource "aws_security_group" "m2_client" {
  vpc_id = aws_vpc.m2_client.id
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

resource "aws_security_group" "m2_service" {
  vpc_id = aws_vpc.m2_service.id
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.lattice.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM for Client EC2
resource "aws_iam_role" "m2_client" {
  name = "skills-lattice-client-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "m2_client_lattice" {
  name = "lattice-list"
  role = aws_iam_role.m2_client.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["vpc-lattice:ListServices", "vpc-lattice:GetService"], Resource = "*" }]
  })
}

resource "aws_iam_role_policy_attachment" "m2_client_ssm" {
  role       = aws_iam_role.m2_client.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "m2_client" {
  name = "skills-lattice-client-profile"
  role = aws_iam_role.m2_client.name
}

# Service EC2
resource "aws_instance" "m2_service" {
  ami                    = data.aws_ami.al2023_tokyo.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.m2_service.id
  vpc_security_group_ids = [aws_security_group.m2_service.id]
  user_data              = file("${path.module}/../app/module2/service/lattice-order-service-userdata.sh")
  tags                   = { Name = "skills-lattice-service-ec2" }
}

# Client EC2
resource "aws_instance" "m2_client" {
  ami                    = data.aws_ami.al2023_tokyo.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.m2_client.id
  vpc_security_group_ids = [aws_security_group.m2_client.id]
  iam_instance_profile   = aws_iam_instance_profile.m2_client.name
  user_data              = file("${path.module}/../app/module2/client/lattice-client-userdata.sh")
  tags                   = { Name = "skills-lattice-client-ec2" }
}

# VPC Lattice
resource "aws_vpclattice_service_network" "m2" {
  name = "skills-lattice-sn"
  tags = { Name = "skills-lattice-sn" }
}

resource "aws_security_group" "m2_lattice_assoc" {
  vpc_id = aws_vpc.m2_client.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.61.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpclattice_service_network_vpc_association" "m2_client" {
  vpc_identifier             = aws_vpc.m2_client.id
  service_network_identifier = aws_vpclattice_service_network.m2.id
  security_group_ids         = [aws_security_group.m2_lattice_assoc.id]
}

resource "aws_vpclattice_target_group" "m2" {
  name = "skills-lattice-order-tg"
  type = "INSTANCE"
  config {
    port           = 8080
    protocol       = "HTTP"
    vpc_identifier = aws_vpc.m2_service.id
    health_check {
      path     = "/health"
      protocol = "HTTP"
    }
  }
  tags = { Name = "skills-lattice-order-tg" }
}

resource "aws_vpclattice_target_group_attachment" "m2" {
  target_group_identifier = aws_vpclattice_target_group.m2.id
  target {
    id   = aws_instance.m2_service.id
    port = 8080
  }
}

resource "aws_vpclattice_service" "m2" {
  name = "skills-lattice-order-service"
  tags = { Name = "skills-lattice-order-service" }
}

resource "aws_vpclattice_service_network_service_association" "m2" {
  service_identifier         = aws_vpclattice_service.m2.id
  service_network_identifier = aws_vpclattice_service_network.m2.id
}

resource "aws_vpclattice_listener" "m2" {
  name               = "skills-lattice-http-listener"
  protocol           = "HTTP"
  port               = 80
  service_identifier = aws_vpclattice_service.m2.id
  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.m2.id
      }
    }
  }
  tags = { Name = "skills-lattice-http-listener" }
}
