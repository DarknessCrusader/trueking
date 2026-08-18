###############################################################################
# Module 3: Cloud Event Handling (ap-southeast-1 Singapore)
###############################################################################

data "aws_availability_zones" "sg" {
  state = "available"
}

data "aws_ami" "al2023_sg" {
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

data "aws_caller_identity" "current" {}

resource "aws_vpc" "m3" {
  cidr_block           = "10.73.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "skills-ceh-vpc" }
}

resource "aws_subnet" "m3" {
  vpc_id                  = aws_vpc.m3.id
  cidr_block              = "10.73.1.0/24"
  availability_zone       = data.aws_availability_zones.sg.names[0]
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "m3" {
  vpc_id = aws_vpc.m3.id
}

resource "aws_route_table" "m3" {
  vpc_id = aws_vpc.m3.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.m3.id
  }
}

resource "aws_route_table_association" "m3" {
  subnet_id      = aws_subnet.m3.id
  route_table_id = aws_route_table.m3.id
}

resource "aws_security_group" "m3_protected" {
  vpc_id = aws_vpc.m3.id
  name   = "skills-ceh-protected-sg"
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "skills-ceh-protected-sg" }
}

resource "aws_instance" "m3" {
  ami                    = data.aws_ami.al2023_sg.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.m3.id
  vpc_security_group_ids = [aws_security_group.m3_protected.id]
  tags                   = { Name = "skills-ceh-ec2" }
}

# SNS Topic
resource "aws_sns_topic" "m3" {
  name = "skills-ceh-alert-topic"
  tags = { Name = "skills-ceh-alert-topic" }
}

# Lambda IAM
resource "aws_iam_role" "m3_lambda" {
  name = "skills-ceh-lambda-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "m3_lambda" {
  name = "skills-ceh-lambda-policy"
  role = aws_iam_role.m3_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ec2:DescribeSecurityGroups", "ec2:RevokeSecurityGroupIngress"], Resource = "*" },
      { Effect = "Allow", Action = ["sns:Publish"], Resource = aws_sns_topic.m3.arn },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" }
    ]
  })
}

# Lambda zip
data "archive_file" "m3_lambda" {
  type        = "zip"
  source_file = "${path.module}/../app/module3/remediate_security_group.py"
  output_path = "${path.module}/../app/module3/lambda.zip"
}

resource "aws_lambda_function" "m3" {
  function_name    = "skills-ceh-remediate-fn"
  role             = aws_iam_role.m3_lambda.arn
  handler          = "remediate_security_group.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.m3_lambda.output_path
  source_code_hash = data.archive_file.m3_lambda.output_base64sha256

  environment {
    variables = {
      PROTECTED_SECURITY_GROUP_ID = aws_security_group.m3_protected.id
      SNS_TOPIC_ARN               = aws_sns_topic.m3.arn
    }
  }

  tags = { Name = "skills-ceh-remediate-fn" }
}

# CloudTrail
resource "aws_s3_bucket" "m3_trail" {
  bucket_prefix = "skills-ceh-trail-"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "m3_trail" {
  bucket = aws_s3_bucket.m3_trail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.m3_trail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.m3_trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      }
    ]
  })
}

resource "aws_cloudtrail" "m3" {
  name                  = "skills-ceh-cloudtrail"
  s3_bucket_name        = aws_s3_bucket.m3_trail.id
  is_multi_region_trail = false
  depends_on            = [aws_s3_bucket_policy.m3_trail]
}

# EventBridge Rule
resource "aws_cloudwatch_event_rule" "m3" {
  name           = "skills-ceh-sg-change-rule"
  event_bus_name = "default"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["AuthorizeSecurityGroupIngress"]
    }
  })
  tags = { Name = "skills-ceh-sg-change-rule" }
}

resource "aws_cloudwatch_event_target" "m3" {
  rule      = aws_cloudwatch_event_rule.m3.name
  target_id = "lambda"
  arn       = aws_lambda_function.m3.arn
}

resource "aws_lambda_permission" "m3" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.m3.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.m3.arn
}
