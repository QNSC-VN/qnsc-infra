# ── AWS Config — resource inventory + compliance rules ─────────────────────────
# Org-level Config recorder delegated to security-audit.
# Delivery channel writes to log-archive S3.

locals {
  config_bucket_name = "qnsc-config-logs-${var.log_archive_account_id}"
}

# S3 bucket in log-archive for Config delivery
resource "aws_s3_bucket" "config" {
  provider      = aws.log_archive
  bucket        = local.config_bucket_name
  force_destroy = false
  tags          = merge(var.tags, { Name = local.config_bucket_name, Purpose = "config-logs" })
}

resource "aws_s3_bucket_versioning" "config" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.config.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  provider                = aws.log_archive
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "config" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.config.arn
        Condition = { StringEquals = { "aws:SourceOrgID" = var.org_id } }
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config.arn}/AWSLogs/*/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"    = "bucket-owner-full-control"
            "aws:SourceOrgID" = var.org_id
          }
        }
      },
    ]
  })
}

# IAM role for Config recorder in security-audit account
resource "aws_iam_role" "config_recorder" {
  provider = aws.security_audit
  name     = "qnsc-config-recorder"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(var.tags, { Name = "qnsc-config-recorder" })
}

resource "aws_iam_role_policy_attachment" "config_recorder" {
  provider   = aws.security_audit
  role       = aws_iam_role.config_recorder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Config recorder (all resource types) in security-audit
resource "aws_config_configuration_recorder" "this" {
  provider = aws.security_audit
  name     = "qnsc-config-recorder"
  role_arn = aws_iam_role.config_recorder.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  provider       = aws.security_audit
  depends_on     = [aws_config_configuration_recorder.this]
  name           = "qnsc-config-delivery"
  s3_bucket_name = aws_s3_bucket.config.id

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }
}

resource "aws_config_configuration_recorder_status" "this" {
  provider   = aws.security_audit
  depends_on = [aws_config_delivery_channel.this]
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
}

# ── Managed Config rules (security-baseline controls) ──────────────────────────
resource "aws_config_config_rule" "s3_bucket_public_read_prohibited" {
  provider   = aws.security_audit
  depends_on = [aws_config_configuration_recorder_status.this]
  name       = "s3-bucket-public-read-prohibited"
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }
}

resource "aws_config_config_rule" "s3_bucket_public_write_prohibited" {
  provider   = aws.security_audit
  depends_on = [aws_config_configuration_recorder_status.this]
  name       = "s3-bucket-public-write-prohibited"
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
  }
}

resource "aws_config_config_rule" "root_mfa_enabled" {
  provider   = aws.security_audit
  depends_on = [aws_config_configuration_recorder_status.this]
  name       = "root-account-mfa-enabled"
  source {
    owner             = "AWS"
    source_identifier = "ROOT_ACCOUNT_MFA_ENABLED"
  }
}

resource "aws_config_config_rule" "ebs_encryption_by_default" {
  provider   = aws.security_audit
  depends_on = [aws_config_configuration_recorder_status.this]
  name       = "ec2-ebs-encryption-by-default"
  source {
    owner             = "AWS"
    source_identifier = "EC2_EBS_ENCRYPTION_BY_DEFAULT"
  }
}

resource "aws_config_config_rule" "iam_no_inline_policy" {
  provider   = aws.security_audit
  depends_on = [aws_config_configuration_recorder_status.this]
  name       = "iam-no-inline-policy-check"
  source {
    owner             = "AWS"
    source_identifier = "IAM_NO_INLINE_POLICY_CHECK"
  }
}
