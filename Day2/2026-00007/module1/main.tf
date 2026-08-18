terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# DynamoDB Reservation Table
resource "aws_dynamodb_table" "reservation" {
  name             = "bigbae-nosql-reservation-table"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "train_id"
  range_key        = "seat_id"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  point_in_time_recovery {
    enabled = true
  }

  attribute {
    name = "train_id"
    type = "S"
  }

  attribute {
    name = "seat_id"
    type = "S"
  }

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "reserved_at"
    type = "S"
  }

  global_secondary_index {
    name            = "gsi-user-reservations"
    hash_key        = "user_id"
    range_key       = "reserved_at"
    projection_type = "ALL"
  }
}

# DynamoDB Audit Table
resource "aws_dynamodb_table" "audit" {
  name         = "bigbae-nosql-audit-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }
}

# Lambda IAM Role
resource "aws_iam_role" "lambda" {
  name = "bigbae-nosql-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "bigbae-nosql-lambda-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.audit.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams"
        ]
        Resource = "${aws_dynamodb_table.reservation.arn}/stream/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# Lambda Function
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "audit" {
  function_name    = "bigbae-nosql-reservation-audit"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda.handler"
  runtime          = "python3.13"
  timeout          = 30
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      AUDIT_TABLE_NAME = aws_dynamodb_table.audit.name
    }
  }
}

# DynamoDB Streams -> Lambda Trigger
resource "aws_lambda_event_source_mapping" "streams" {
  event_source_arn  = aws_dynamodb_table.reservation.stream_arn
  function_name     = aws_lambda_function.audit.arn
  starting_position = "LATEST"
  batch_size        = 10
}

# EC2 Instance
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "bigbae-nosql-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "bigbae-nosql-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "ap-southeast-1a"
  tags                    = { Name = "bigbae-nosql-pub-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "bigbae-nosql-pub-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "app" {
  name        = "bigbae-nosql-app-sg"
  description = "Security group for NoSQL app EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 IAM Role
resource "aws_iam_role" "ec2" {
  name = "bigbae-nosql-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2" {
  name = "bigbae-nosql-ec2-policy"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ]
      Resource = [
        aws_dynamodb_table.reservation.arn,
        "${aws_dynamodb_table.reservation.arn}/index/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "bigbae-nosql-ec2-profile"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids      = [aws_security_group.app.id]
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true

  user_data = <<-EOF
#!/bin/bash
dnf install -y python3.11 python3.11-pip
pip3.11 install flask boto3
mkdir -p /opt/app
cat > /opt/app/app.py << 'APPEOF'
${file("${path.module}/app.py")}
APPEOF
cd /opt/app
export AWS_REGION=ap-southeast-1
export TABLE_NAME=bigbae-nosql-reservation-table
export GSI_NAME=gsi-user-reservations
nohup python3.11 app.py &
EOF

  tags = {
    Name = "bigbae-nosql-app-ec2"
  }
}
