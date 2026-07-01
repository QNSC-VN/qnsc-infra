# ── Service Control Policies (preventive guardrails, architecture §10) ─────────
# SCPs are deny-overlays on top of the AWS-managed FullAWSAccess policy. They do
# NOT apply to the management account, so we keep the management account empty.

# 1) Region lock — deny actions outside approved regions. Global/region-agnostic
#    services are excepted via NotAction so IAM/CloudFront/Route53/etc. keep working.
resource "aws_organizations_policy" "region_lock" {
  name        = "deny-leave-approved-regions"
  description = "Deny actions outside approved regions (global services excepted)."
  type        = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "RegionLock"
      Effect   = "Deny"
      Resource = "*"
      NotAction = [
        "a4b:*", "access-analyzer:*", "account:*", "acm:*", "aws-marketplace:*",
        "aws-portal:*", "billing:*", "budgets:*", "ce:*", "chime:*", "cloudfront:*",
        "cur:*", "globalaccelerator:*", "health:*", "iam:*", "importexport:*",
        "kms:*", "organizations:*", "route53:*", "route53domains:*", "s3:GetBucketLocation",
        "s3:ListAllMyBuckets", "shield:*", "sts:*", "support:*", "tag:*", "trustedadvisor:*",
        "waf:*", "wafv2:*", "waf-regional:*", "cloudtrail:*"
      ]
      Condition = {
        StringNotEquals = { "aws:RequestedRegion" = var.approved_regions }
      }
    }]
  })
  tags = var.tags
}

# 2) Protect the audit spine — no one may disable logging/detection.
resource "aws_organizations_policy" "protect_security" {
  name        = "deny-disable-security-services"
  description = "Deny disabling CloudTrail, Config, GuardDuty, Security Hub."
  type        = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ProtectSecurityServices"
      Effect   = "Deny"
      Resource = "*"
      Action = [
        "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
        "config:DeleteConfigurationRecorder", "config:StopConfigurationRecorder",
        "config:DeleteDeliveryChannel", "config:DeleteConfigRule",
        "guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount",
        "guardduty:UpdateDetector", "guardduty:StopMonitoringMembers",
        "securityhub:DisableSecurityHub", "securityhub:DisassociateFromAdministratorAccount",
        "securityhub:DeleteInvitations"
      ]
    }]
  })
  tags = var.tags
}

# 3) No root-user usage in member accounts (break-glass excepted at process level).
resource "aws_organizations_policy" "deny_root" {
  name        = "deny-root-user-actions"
  description = "Deny all actions performed by the account root user."
  type        = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyRoot"
      Effect    = "Deny"
      Action    = "*"
      Resource  = "*"
      Condition = { StringLike = { "aws:PrincipalArn" = "arn:aws:iam::*:root" } }
    }]
  })
  tags = var.tags
}

# 4) No long-lived IAM users / access keys — force SSO + roles + OIDC.
resource "aws_organizations_policy" "deny_iam_users" {
  name        = "deny-iam-users-and-keys"
  description = "Deny creating IAM users and access keys (use SSO/roles/OIDC)."
  type        = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyIamUsers"
      Effect   = "Deny"
      Resource = "*"
      Action   = ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile"]
    }]
  })
  tags = var.tags
}

# 5) Require IMDSv2 on EC2 (token-based metadata — blocks SSRF credential theft).
resource "aws_organizations_policy" "require_imdsv2" {
  name        = "require-imdsv2"
  description = "Deny RunInstances unless IMDSv2 (HttpTokens=required) is enforced."
  type        = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "RequireImdsv2"
      Effect    = "Deny"
      Action    = "ec2:RunInstances"
      Resource  = "arn:aws:ec2:*:*:instance/*"
      Condition = { StringNotEquals = { "ec2:MetadataHttpTokens" = "required" } }
    }]
  })
  tags = var.tags
}

# ── Attachments ────────────────────────────────────────────────────────────────
# Org-wide safety (root → all member accounts; never the management account):
locals {
  root_id        = aws_organizations_organization.this.roots[0].id
  root_scps      = [aws_organizations_policy.deny_root.id, aws_organizations_policy.protect_security.id]
  workloads_scps = [aws_organizations_policy.region_lock.id, aws_organizations_policy.deny_iam_users.id, aws_organizations_policy.require_imdsv2.id]
}

resource "aws_organizations_policy_attachment" "root" {
  for_each  = toset(local.root_scps)
  policy_id = each.value
  target_id = local.root_id
}

resource "aws_organizations_policy_attachment" "workloads" {
  for_each  = toset(local.workloads_scps)
  policy_id = each.value
  target_id = aws_organizations_organizational_unit.workloads.id
}
