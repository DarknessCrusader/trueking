terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

data "aws_caller_identity" "current" {}

# ============================================================
# VPC
# ============================================================
resource "aws_vpc" "event_vpc" {
  cidr_block           = "172.16.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "event-vpc" }
}

resource "aws_internet_gateway" "event_igw" {
  vpc_id = aws_vpc.event_vpc.id
  tags   = { Name = "event-igw" }
}

resource "aws_subnet" "event_pub_a" {
  vpc_id                  = aws_vpc.event_vpc.id
  cidr_block              = "172.16.0.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "event-pub-a" }
}

resource "aws_subnet" "event_pub_b" {
  vpc_id                  = aws_vpc.event_vpc.id
  cidr_block              = "172.16.1.0/24"
  availability_zone       = "eu-west-1b"
  map_public_ip_on_launch = true
  tags                    = { Name = "event-pub-b" }
}

resource "aws_route_table" "event_pub_rtb" {
  vpc_id = aws_vpc.event_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.event_igw.id
  }
  tags = { Name = "event-pub-rtb" }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.event_pub_a.id
  route_table_id = aws_route_table.event_pub_rtb.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.event_pub_b.id
  route_table_id = aws_route_table.event_pub_rtb.id
}

# ============================================================
# IAM - EC2
# ============================================================
resource "aws_iam_role" "ec2_role" {
  name = "wsc2026-event-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "wsc2026-event-ec2-role"
  role = aws_iam_role.ec2_role.name
}

# AdminAccessRole (채점 테스트용)
resource "aws_iam_role" "admin_role" {
  name = "AdminAccessRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "admin_access" {
  role       = aws_iam_role.admin_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "admin_profile" {
  name = "AdminAccessRole"
  role = aws_iam_role.admin_role.name
}

# ============================================================
# IAM - Lambda
# ============================================================
resource "aws_iam_role" "lambda_role" {
  name = "wsc2026-event-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "wsc2026-event-lambda-policy"
  role = aws_iam_role.lambda_role.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SNS"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = "arn:aws:sns:eu-west-1:${data.aws_caller_identity.current.account_id}:wsc2026-event-alert"
      },
      {
        Sid    = "EC2"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstanceAttribute",
          "ec2:DescribeIamInstanceProfileAssociations",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:AssociateIamInstanceProfile",
          "ec2:ReplaceIamInstanceProfileAssociation",
          "ec2:StopInstances",
          "ec2:StartInstances",
          "ec2:ModifyInstanceAttribute"
        ]
        Resource = "*"
      },
      {
        Sid      = "PassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/wsc2026-event-ec2-role"
        Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
      }
    ]
  })
}

# ============================================================
# Security Group
# ============================================================
resource "aws_security_group" "event_sg" {
  name        = "wsc2026-event-sg"
  description = "Security group for event EC2 instance"
  vpc_id      = aws_vpc.event_vpc.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc2026-event-sg" }
}

# ============================================================
# EC2
# ============================================================
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "event_ec2" {
  ami                     = data.aws_ami.al2023.id
  instance_type           = "t3.micro"
  subnet_id               = aws_subnet.event_pub_a.id
  vpc_security_group_ids  = [aws_security_group.event_sg.id]
  iam_instance_profile    = aws_iam_instance_profile.ec2_profile.name
  disable_api_termination = true
  user_data_base64        = base64encode("#!/bin/bash\ndnf update -y\ndnf install httpd -y\nsystemctl enable --now httpd\nhostname > /var/www/html/index.html")
  tags                    = { Name = "wsc2026-event-ec2" }
}

# ============================================================
# SNS
# ============================================================
resource "aws_sns_topic" "alert" {
  name = "wsc2026-event-alert"
}

# ============================================================
# CloudTrail
# ============================================================
resource "aws_s3_bucket" "trail_bucket" {
  bucket        = "wsc2026-event-s3"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "trail_bucket_policy" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail_bucket.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = ["arn:aws:cloudtrail:eu-west-1:${data.aws_caller_identity.current.account_id}:trail/wsc2026-event-trail"]
    }
  }
  statement {
    sid       = "AWSCloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail_bucket.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = ["arn:aws:cloudtrail:eu-west-1:${data.aws_caller_identity.current.account_id}:trail/wsc2026-event-trail"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail_bucket.id
  policy = data.aws_iam_policy_document.trail_bucket_policy.json
}

resource "aws_cloudtrail" "event" {
  name                          = "wsc2026-event-trail"
  s3_bucket_name                = aws_s3_bucket.trail_bucket.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_logging                = true
  enable_log_file_validation    = true
  depends_on                    = [aws_s3_bucket_policy.trail]
}

# ============================================================
# Lambda Functions (과제지 lambda.md 기준 4개)
# ============================================================
data "archive_file" "sg" {
  type        = "zip"
  output_path = "${path.module}/lambda/sg.zip"
  source {
    content  = file("${path.module}/lambda/sg.py")
    filename = "index.py"
  }
}

data "archive_file" "role" {
  type        = "zip"
  output_path = "${path.module}/lambda/role.zip"
  source {
    content  = file("${path.module}/lambda/role.py")
    filename = "index.py"
  }
}

data "archive_file" "terminate" {
  type        = "zip"
  output_path = "${path.module}/lambda/terminate.zip"
  source {
    content  = file("${path.module}/lambda/termination.py")
    filename = "index.py"
  }
}

data "archive_file" "type" {
  type        = "zip"
  output_path = "${path.module}/lambda/type.zip"
  source {
    content  = file("${path.module}/lambda/type.py")
    filename = "index.py"
  }
}

locals {
  lambda_functions = {
    "wsc2026-sg-remediation" = {
      zip  = data.archive_file.sg.output_path
      hash = data.archive_file.sg.output_base64sha256
      timeout = 30
      environment = {
        SNS_TOPIC_ARN     = aws_sns_topic.alert.arn
        SECURITY_GROUP_ID = aws_security_group.event_sg.id
      }
    }
    "wsc2026-role-remediation" = {
      zip  = data.archive_file.role.output_path
      hash = data.archive_file.role.output_base64sha256
      timeout = 30
      environment = {
        SNS_TOPIC_ARN = aws_sns_topic.alert.arn
        INSTANCE_ID   = aws_instance.event_ec2.id
        ROLE_NAME     = aws_iam_instance_profile.ec2_profile.name
      }
    }
    "wsc2026-ec2-terminate-alert" = {
      zip  = data.archive_file.terminate.output_path
      hash = data.archive_file.terminate.output_base64sha256
      timeout = 30
      environment = {
        SNS_TOPIC_ARN     = aws_sns_topic.alert.arn
        INSTANCE_ID       = aws_instance.event_ec2.id
        SECURITY_GROUP_ID = aws_security_group.event_sg.id
      }
    }
    "wsc2026-ec2-type-remediation" = {
      zip  = data.archive_file.type.output_path
      hash = data.archive_file.type.output_base64sha256
      timeout = 180
      environment = {
        SNS_TOPIC_ARN = aws_sns_topic.alert.arn
        INSTANCE_ID   = aws_instance.event_ec2.id
        INSTANCE_TYPE = "t3.micro"
      }
    }
  }
}

resource "aws_lambda_function" "fn" {
  for_each         = local.lambda_functions
  function_name    = each.key
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = each.value.zip
  source_code_hash = each.value.hash
  timeout          = each.value.timeout

  environment {
    variables = each.value.environment
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic]
}

# ============================================================
# EventBridge Rules (과제지 기준 4개)
# ============================================================
resource "aws_cloudwatch_event_rule" "sg_change" {
  name = "wsc2026-sg-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource       = ["ec2.amazonaws.com"]
      eventName         = ["AuthorizeSecurityGroupIngress"]
      requestParameters = { groupId = [aws_security_group.event_sg.id] }
    }
  })
}

resource "aws_cloudwatch_event_rule" "role_change" {
  name = "wsc2026-role-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["AssociateIamInstanceProfile", "ReplaceIamInstanceProfileAssociation", "DisassociateIamInstanceProfile"]
    }
  })
}

resource "aws_cloudwatch_event_rule" "ec2_terminate" {
  name = "wsc2026-ec2-terminate-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail      = { state = ["stopped", "terminated"], "instance-id" = [aws_instance.event_ec2.id] }
  })
}

resource "aws_cloudwatch_event_rule" "ec2_type_change" {
  name = "wsc2026-ec2-type-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["ModifyInstanceAttribute"]
      requestParameters = {
        instanceId   = [aws_instance.event_ec2.id]
        instanceType = { value = [{ "anything-but" = "t3.micro" }] }
      }
    }
  })
}

locals {
  event_targets = {
    sg = {
      rule     = aws_cloudwatch_event_rule.sg_change.name
      rule_arn = aws_cloudwatch_event_rule.sg_change.arn
      function = "wsc2026-sg-remediation"
    }
    role = {
      rule     = aws_cloudwatch_event_rule.role_change.name
      rule_arn = aws_cloudwatch_event_rule.role_change.arn
      function = "wsc2026-role-remediation"
    }
    terminate = {
      rule     = aws_cloudwatch_event_rule.ec2_terminate.name
      rule_arn = aws_cloudwatch_event_rule.ec2_terminate.arn
      function = "wsc2026-ec2-terminate-alert"
    }
    type = {
      rule     = aws_cloudwatch_event_rule.ec2_type_change.name
      rule_arn = aws_cloudwatch_event_rule.ec2_type_change.arn
      function = "wsc2026-ec2-type-remediation"
    }
  }
}

resource "aws_cloudwatch_event_target" "lambda" {
  for_each  = local.event_targets
  rule      = each.value.rule
  target_id = "${each.key}-target"
  arn       = aws_lambda_function.fn[each.value.function].arn
}

resource "aws_lambda_permission" "eventbridge" {
  for_each      = local.event_targets
  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.value.function].function_name
  principal     = "events.amazonaws.com"
  source_arn    = each.value.rule_arn
}

# ============================================================
# AWS Config (선택 - 필요 시 활성화)
# ============================================================
resource "aws_config_configuration_recorder" "main" {
  name     = "default"
  role_arn = aws_iam_role.config_role.arn
  recording_group {
    all_supported = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "default"
  s3_bucket_name = aws_s3_bucket.config_bucket.id
  depends_on     = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

resource "aws_s3_bucket" "config_bucket" {
  bucket        = "wsc2026-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ConfigBucketAcl"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.config_bucket.arn
      },
      {
        Sid       = "ConfigBucketWrite"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config_bucket.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      }
    ]
  })
}

resource "aws_iam_role" "config_role" {
  name = "wsc2026-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "config.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "config_policy" {
  role       = aws_iam_role.config_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_config_rule" "sg_ssh" {
  name = "wsc2026-sg-ssh-rule"
  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }
  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "required_tags" {
  name = "wsc2026-required-tags-rule"
  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }
  input_parameters = jsonencode({ tag1Key = "Name" })
  scope {
    compliance_resource_types = ["AWS::EC2::Instance"]
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}

# ============================================================
# Outputs
# ============================================================
output "instance_id" { value = aws_instance.event_ec2.id }
output "security_group_id" { value = aws_security_group.event_sg.id }
output "sns_topic_arn" { value = aws_sns_topic.alert.arn }
