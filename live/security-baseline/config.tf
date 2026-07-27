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

  # Record every supported type EXCEPT the ones that churn with deploys rather
  # than with configuration intent. Config bills $0.003 per configuration item,
  # and the July bill recorded 19,819 of them (~$59, the single largest line on
  # the account) at ~730/day. That rate tracks deploy frequency, not resource
  # count: every Fargate task launch creates and deletes a task ENI, and every
  # image push registers a new ECS task-definition revision, across four stacks
  # (rally + opshub × develop + prod).
  #
  # None of the excluded types is evaluated by any rule in `config_managed_rules`
  # below, and CloudTrail — not Config — is the audit record for who deployed
  # what. Excluding them removes the churn without narrowing compliance scope.
  #
  # EXCLUSION_BY_RESOURCE_TYPES keeps recording global (IAM) types by default,
  # which IAM_USER_NO_POLICIES_CHECK needs; `include_global_resource_types` must
  # stay unset because the API rejects it alongside an exclusion strategy.
  recording_group {
    all_supported = false

    # Every entry must be a type AWS Config actually supports, or the recorder
    # update fails with InvalidParameterValueException — the provider passes this
    # list straight through without validating it. `AWS::ECS::Task` is deliberately
    # absent for that reason: Config records ECS clusters, services, task
    # definitions and task sets, not individual tasks. Task churn reaches Config as
    # NetworkInterface events instead, which is the first entry below.
    exclusion_by_resource_types {
      resource_types = [
        "AWS::EC2::NetworkInterface", # one create + one delete per Fargate task
        "AWS::ECS::TaskDefinition",   # a new revision on every image push
        "AWS::ECS::Service",          # changes on every rolling deploy
        "AWS::ECS::TaskSet",
      ]
    }

    recording_strategy {
      use_only = "EXCLUSION_BY_RESOURCE_TYPES"
    }
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
