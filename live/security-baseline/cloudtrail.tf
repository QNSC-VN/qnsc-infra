# ── Org CloudTrail → log-archive S3 ───────────────────────────────────────────
# Single org-wide trail: management account creates it, delivers to S3 in log-archive.
# All member accounts emit events automatically (is_organization_trail = true).

locals {
  trail_bucket_name = "qnsc-cloudtrail-logs-${var.log_archive_account_id}"
}

# KMS key for CloudTrail encryption (created in management, log-archive uses it via policy)
resource "aws_kms_key" "cloudtrail" {
  description             = "Encrypts org CloudTrail logs."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowKeyAdminByManagement"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.management.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudTrailEncrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringLike = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${data.aws_caller_identity.management.account_id}:trail/*" }
        }
      },
    ]
  })

  tags = merge(var.tags, { Name = "qnsc-cloudtrail-key" })
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/qnsc-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail.key_id
}

# S3 bucket in log-archive account
resource "aws_s3_bucket" "cloudtrail" {
  provider      = aws.log_archive
  bucket        = local.trail_bucket_name
  force_destroy = false

  tags = merge(var.tags, { Name = local.trail_bucket_name, Purpose = "cloudtrail-logs" })
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.cloudtrail.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudtrail.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.cloudtrail.id
  rule {
    id     = "transition-and-expire"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 365
      storage_class = "GLACIER"
    }
    expiration { days = 2557 } # 7 years for compliance
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  provider                = aws.log_archive
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
        Condition = { StringEquals = { "aws:SourceArn" = "arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.management.account_id}:trail/qnsc-org-trail" } }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.management.account_id}:trail/qnsc-org-trail"
          }
        }
      },
      {
        Sid       = "AWSCloudTrailOrgWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${var.org_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.management.account_id}:trail/qnsc-org-trail"
          }
        }
      },
    ]
  })
}

# Org-wide CloudTrail (management account; is_organization_trail covers all member accounts)
resource "aws_cloudtrail" "org" {
  depends_on = [aws_s3_bucket_policy.cloudtrail]

  name                          = "qnsc-org-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail         = true
  is_organization_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.cloudtrail.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::"]
    }
  }

  tags = merge(var.tags, { Name = "qnsc-org-trail" })
}
