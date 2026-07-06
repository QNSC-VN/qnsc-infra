# =============================================================================
# security-baseline — account-wide audit & threat-detection baseline.
#
# One stack, applied once per account, that gives the platform its management-
# plane audit trail and detective controls (SOC 2 CC7.x / enterprise baseline):
#   - CloudTrail  — multi-region trail, log-file validation, KMS-encrypted, to a
#                   locked, versioned, TLS-only S3 bucket.
#   - AWS Config  — records all resource config + a core set of managed rules.
#   - GuardDuty   — continuous threat detection.
#   - Access Analyzer — flags resources shared outside the account.
#
# Additive only — provisions no product resources and touches nothing the
# bootstrap/product stacks own. Uses its own dedicated audit CMK (not the
# platform CMK) so it never has to reach into the bootstrap key policy.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/security-baseline/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Org       = "qnsc"
      ManagedBy = "opentofu"
      Layer     = "platform"
      Stack     = "security-baseline"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  bucket     = "qnsc-audit-logs-${local.account_id}"
}

# ── Dedicated audit-logs CMK ─────────────────────────────────────────────────
# Separate from the platform CMK: audit logs are their own trust domain, and
# CloudTrail/Config need service-specific key-policy grants we don't want to add
# to the shared application key.
resource "aws_kms_key" "audit" {
  description             = "qnsc audit logs (CloudTrail + Config)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudTrailEncrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringLike = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*" }
        }
      },
      {
        Sid       = "ConfigEncrypt"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "audit" {
  name          = "alias/qnsc-audit-logs"
  target_key_id = aws_kms_key.audit.key_id
}

# ── Locked audit-logs bucket (CloudTrail + Config share it, distinct prefixes) ─
resource "aws_s3_bucket" "audit" {
  bucket = local.bucket
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 180
      storage_class = "GLACIER"
    }
    expiration { days = 2555 } # 7 years — SOC 2 / audit retention
    noncurrent_version_expiration { noncurrent_days = 90 }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.audit.arn
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.audit.arn}/cloudtrail/AWSLogs/${local.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
      {
        Sid       = "ConfigAclCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.audit.arn
      },
      {
        Sid       = "ConfigWrite"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.audit.arn}/config/AWSLogs/${local.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
    ]
  })
}

# ── GuardDuty — continuous threat detection ──────────────────────────────────
resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "SIX_HOURS"

  datasources {
    s3_logs { enable = true }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes { enable = true }
      }
    }
  }
}

# ── IAM Access Analyzer — external-access findings ───────────────────────────
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "qnsc-account-analyzer"
  type          = "ACCOUNT"
}
