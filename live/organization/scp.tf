# =============================================================================
# scp.tf — baseline Service Control Policies + attachments.
#
# SCPs are free and are the org's preventive guardrails. They cap what any
# principal (including root) can do; they never grant. Attachment strategy is
# deliberately lockout-safe for a single management account today:
#
#   ALWAYS attached to ROOT (safe with the built-in carve-outs):
#     - region-lock        (global services exempted so mgmt never locks out)
#     - deny-disable-logging (automation roles exempted so tofu can still manage)
#     - deny-leave-org
#
#   Attached to the WORKLOADS OU (future dev/prod member accounts):
#     - deny-iam-user-keys (humans use SSO; workloads use roles — never users)
#
#   Gated behind enforce_strict_guardrails (default false — enable ONLY after an
#   Identity Center admin path exists, else you can lock yourself out of root):
#     - deny-root          → root
#     - deny-iam-user-keys → root (management account too)
#
# See README.md "SCP safety" before flipping enforce_strict_guardrails.
# =============================================================================

# ── region-lock ───────────────────────────────────────────────────────────────
# Deny everything outside the allowed regions, EXCEPT genuinely global services
# whose endpoints live in us-east-1 (IAM, STS, Organizations, CloudFront,
# Route 53, WAF/Shield, Identity Center, billing, support …). Without this
# carve-out a region-lock bricks the management account. us-east-1 stays allowed
# for ACM-for-CloudFront and other global-console operations.
resource "aws_organizations_policy" "region_lock" {
  name        = "qnsc-region-lock"
  description = "Deny API calls outside allowed regions (global services exempt)."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyOutsideAllowedRegions"
      Effect    = "Deny"
      Resource  = "*"
      Condition = { StringNotEquals = { "aws:RequestedRegion" = var.allowed_regions } }
      NotAction = [
        "a4b:*", "account:*", "acm:*", "aws-marketplace:*", "aws-marketplace-management:*",
        "aws-portal:*", "billing:*", "budgets:*", "ce:*", "chime:*", "cloudfront:*",
        "cur:*", "globalaccelerator:*", "health:*", "iam:*", "identitystore:*",
        "importexport:*", "kms:*", "notifications:*", "organizations:*", "route53:*",
        "route53domains:*", "shield:*", "sso:*", "sso-directory:*", "sts:*", "support:*",
        "tag:*", "trustedadvisor:*", "waf:*", "waf-regional:*", "wafv2:*",
      ]
    }]
  })
}

# ── deny-disable-logging ──────────────────────────────────────────────────────
# Block tearing down the detective controls the security-baseline stack owns.
# Automation roles (tofu apply) are exempted so the baseline can still be
# managed — only interactive/other principals are denied the destructive verbs.
resource "aws_organizations_policy" "deny_disable_logging" {
  name        = "qnsc-deny-disable-logging"
  description = "Deny disabling CloudTrail / Config / GuardDuty / Access Analyzer."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyDisableSecurityServices"
      Effect = "Deny"
      Action = [
        "cloudtrail:StopLogging", "cloudtrail:DeleteTrail",
        "config:DeleteConfigurationRecorder", "config:StopConfigurationRecorder",
        "config:DeleteDeliveryChannel", "config:DeleteConfigRule",
        "guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount",
        "guardduty:StopMonitoringMembers", "guardduty:DeleteMembers",
        "accessanalyzer:DeleteAnalyzer",
      ]
      Resource = "*"
      Condition = length(var.logging_guardrail_exempt_role_arns) > 0 ? {
        ArnNotLike = { "aws:PrincipalArn" = var.logging_guardrail_exempt_role_arns }
      } : {}
    }]
  })
}

# ── deny-leave-org ────────────────────────────────────────────────────────────
resource "aws_organizations_policy" "deny_leave_org" {
  name        = "qnsc-deny-leave-org"
  description = "Prevent a member account from leaving the organization."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyLeaveOrganization"
      Effect   = "Deny"
      Action   = ["organizations:LeaveOrganization"]
      Resource = "*"
    }]
  })
}

# ── deny-iam-user-keys ────────────────────────────────────────────────────────
# Humans authenticate via Identity Center (SSO); workloads use roles. Long-lived
# IAM users and static access keys are the #1 credential-leak vector — forbid
# creating them. (Role creation, used by iam-oidc, is unaffected.)
resource "aws_organizations_policy" "deny_iam_user_keys" {
  name        = "qnsc-deny-iam-user-keys"
  description = "Deny creating IAM users / access keys / login profiles."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyIamUsersAndStaticKeys"
      Effect = "Deny"
      Action = [
        "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile",
        "iam:CreateServiceSpecificCredential", "iam:UpdateAccessKey",
        "iam:UpdateLoginProfile",
      ]
      Resource = "*"
    }]
  })
}

# ── deny-root ─────────────────────────────────────────────────────────────────
# The account root user should never take day-to-day actions. Enforced only when
# enforce_strict_guardrails = true (ensure an Identity Center admin path exists
# first, or you can lock yourself out).
resource "aws_organizations_policy" "deny_root" {
  name        = "qnsc-deny-root"
  description = "Deny all actions by the account root user."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyRootUser"
      Effect    = "Deny"
      Action    = "*"
      Resource  = "*"
      Condition = { StringLike = { "aws:PrincipalArn" = "arn:aws:iam::*:root" } }
    }]
  })
}

# ── Attachments ───────────────────────────────────────────────────────────────
# Root-level, always (lockout-safe).
resource "aws_organizations_policy_attachment" "root_region_lock" {
  policy_id = aws_organizations_policy.region_lock.id
  target_id = local.root_id
}

resource "aws_organizations_policy_attachment" "root_deny_disable_logging" {
  policy_id = aws_organizations_policy.deny_disable_logging.id
  target_id = local.root_id
}

resource "aws_organizations_policy_attachment" "root_deny_leave_org" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = local.root_id
}

# Workloads OU — future dev/prod member accounts.
resource "aws_organizations_policy_attachment" "workloads_deny_iam_user_keys" {
  policy_id = aws_organizations_policy.deny_iam_user_keys.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

# Strict, root-level — enable only after an SSO admin path exists.
resource "aws_organizations_policy_attachment" "root_deny_root" {
  count     = var.enforce_strict_guardrails ? 1 : 0
  policy_id = aws_organizations_policy.deny_root.id
  target_id = local.root_id
}

resource "aws_organizations_policy_attachment" "root_deny_iam_user_keys" {
  count     = var.enforce_strict_guardrails ? 1 : 0
  policy_id = aws_organizations_policy.deny_iam_user_keys.id
  target_id = local.root_id
}
