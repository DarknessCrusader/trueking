terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "skillsphone-landing-ab-${local.account_id}"
}

# S3 Bucket
resource "aws_s3_bucket" "landing" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "landing" {
  bucket                  = aws_s3_bucket.landing.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "index_a" {
  bucket       = aws_s3_bucket.landing.id
  key          = "version-a/index.html"
  source       = "${path.module}/index_a.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/index_a.html")
}

resource "aws_s3_object" "index_b" {
  bucket       = aws_s3_bucket.landing.id
  key          = "version-b/index.html"
  source       = "${path.module}/index_b.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/index_b.html")
}

# OAC
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "skillsphone-landing-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# S3 Bucket Policy for CloudFront OAC
resource "aws_s3_bucket_policy" "landing" {
  bucket = aws_s3_bucket.landing.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.landing.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.ab.arn
        }
      }
    }]
  })
}

# KeyValueStore
resource "aws_cloudfront_key_value_store" "ab_config" {
  name = "skillsphone-cdn-ab-config"
}

resource "aws_cloudfrontkeyvaluestore_key" "weight" {
  key_value_store_arn = aws_cloudfront_key_value_store.ab_config.arn
  key                 = "weight"
  value               = "0.3"
}

resource "aws_cloudfrontkeyvaluestore_key" "version_a" {
  key_value_store_arn = aws_cloudfront_key_value_store.ab_config.arn
  key                 = "version_a"
  value               = "/version-a/index.html"
}

resource "aws_cloudfrontkeyvaluestore_key" "version_b" {
  key_value_store_arn = aws_cloudfront_key_value_store.ab_config.arn
  key                 = "version_b"
  value               = "/version-b/index.html"
}

# CloudFront Functions
resource "aws_cloudfront_function" "viewer_request" {
  name    = "skillsphone-cdn-ab-req-fn"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = file("${path.module}/cf_req_fn.js")

  key_value_store_associations = [aws_cloudfront_key_value_store.ab_config.arn]
}

resource "aws_cloudfront_function" "viewer_response" {
  name    = "skillsphone-cdn-ab-res-fn"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = file("${path.module}/cf_res_fn.js")
}

# Cache Policy
resource "aws_cloudfront_cache_policy" "ab" {
  name        = "skillsphone-cdn-ab-cache-policy"
  min_ttl     = 0
  default_ttl = 300
  max_ttl     = 3600

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "whitelist"
      cookies {
        items = ["x-sp-ab"]
      }
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

# Response Headers Policy
resource "aws_cloudfront_response_headers_policy" "security" {
  name = "skillsphone-cdn-ab-security-headers"

  security_headers_config {
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }
  }
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "ab" {
  comment         = "skillsphone-cdn-ab-distribution"
  enabled         = true
  price_class     = "PriceClass_All"
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.landing.bucket_regional_domain_name
    origin_id                = "s3-landing"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "s3-landing"
    viewer_protocol_policy   = "redirect-to-https"
    cache_policy_id          = aws_cloudfront_cache_policy.ab.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.viewer_request.arn
    }

    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.viewer_response.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "skillsphone-cdn-ab-distribution"
  }
}
