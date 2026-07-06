# ── AWS Config — resource configuration recording + core compliance rules ────

# Service-linked-style role Config assumes to read resource config + write to S3.
resource "aws_iam_role" "config" {
  name = "qnsc-config-recorder"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Allow Config to deliver snapshots to the audit bucket under its prefix.
resource "aws_iam_role_policy" "config_s3" {
  name = "config-s3-delivery"
  role = aws_iam_role.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PutConfig"
        Effect    = "Allow"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.audit.arn}/config/AWSLogs/${local.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
      { Sid = "GetBucketAcl", Effect = "Allow", Action = "s3:GetBucketAcl", Resource = aws_s3_bucket.audit.arn },
      { Sid = "UseAuditKey", Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"], Resource = aws_kms_key.audit.arn },
    ]
  })
}

resource "aws_config_configuration_recorder" "this" {
  name     = "qnsc-recorder"
  role_arn = aws_iam_role.config.arn
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "qnsc-delivery"
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_key_prefix  = "config"
  s3_kms_key_arn = aws_kms_key.audit.arn
  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }
  depends_on = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.audit]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

# ── Core managed rules — high-signal baseline (extend as needed) ─────────────
locals {
  config_managed_rules = {
    s3-public-read-prohibited  = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
    s3-public-write-prohibited = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
    encrypted-volumes          = "ENCRYPTED_VOLUMES"
    rds-storage-encrypted      = "RDS_STORAGE_ENCRYPTED"
    rds-public-access-check    = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK"
    iam-user-no-policies       = "IAM_USER_NO_POLICIES_CHECK"
    cloudtrail-enabled         = "CLOUD_TRAIL_ENABLED"
    root-mfa-enabled           = "ROOT_ACCOUNT_MFA_ENABLED"
  }
}

resource "aws_config_config_rule" "managed" {
  for_each = local.config_managed_rules

  name = each.key
  source {
    owner             = "AWS"
    source_identifier = each.value
  }
  depends_on = [aws_config_configuration_recorder.this]
}
