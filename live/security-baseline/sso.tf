# ── IAM Identity Center (SSO) + Microsoft Entra ID federation ─────────────────
#
# Architecture:
#   Microsoft Entra ID (M365/Azure AD) → SAML 2.0 → IAM Identity Center
#   SCIM provisioning syncs users/groups from Entra → IAM Identity Center automatically
#
# OpenTofu manages:
#   - Permission sets (what access each role gets)
#   - Account assignments (which groups get which permission set in which account)
#
# Manual step (one-time, ~15 min in console — see README):
#   - Register "AWS IAM Identity Center" SAML app in Entra portal
#   - Upload Entra SAML metadata XML into IAM Identity Center → Settings → External IdP
#   - Enable SCIM provisioning (paste SCIM endpoint URL + token into Entra)
#   After this, groups synced from Entra flow into `aws_identitystore_group` data sources.

# IAM Identity Center must be ENABLED first (console: IAM Identity Center → Enable).
# After enable, the instance ARN is auto-created — we read it as a data source.
data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  sso_identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

# ── Permission Sets ─────────────────────────────────────────────────────────────

# Full admin — break-glass / platform team only
resource "aws_ssoadmin_permission_set" "administrator" {
  name             = "AdministratorAccess"
  description      = "Full AWS administrator — break-glass and platform team only."
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H" # 4 h max session — force re-auth
  tags             = var.tags
}

resource "aws_ssoadmin_managed_policy_attachment" "administrator" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Developer — full access to dev, read-only everywhere else
resource "aws_ssoadmin_permission_set" "developer" {
  name             = "DeveloperAccess"
  description      = "Developer: PowerUser in dev/staging, ReadOnly in prod."
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
  tags             = var.tags
}

resource "aws_ssoadmin_managed_policy_attachment" "developer" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.developer.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# Read-only — auditors, finance, execs viewing prod
resource "aws_ssoadmin_permission_set" "readonly" {
  name             = "ReadOnlyAccess"
  description      = "Read-only across all accounts."
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
  tags             = var.tags
}

resource "aws_ssoadmin_managed_policy_attachment" "readonly" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.readonly.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Security auditor — SecurityAudit policy (read Config, GuardDuty, CloudTrail findings)
resource "aws_ssoadmin_permission_set" "security_auditor" {
  name             = "SecurityAuditor"
  description      = "Read security findings across all accounts."
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
  tags             = var.tags
}

resource "aws_ssoadmin_managed_policy_attachment" "security_auditor" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.security_auditor.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

# ── Account assignments ────────────────────────────────────────────────────────
# Groups below are provisioned from Entra via SCIM.
# Replace the group_id values after SCIM sync completes (see README).
#
# Pattern: group_id comes from Entra SCIM push. After sync:
#   data "aws_identitystore_group" "platform_team" {
#     identity_store_id = local.sso_identity_store_id
#     filter { attribute_path = "DisplayName", attribute_value = "AWS-PlatformTeam" }
#   }
# Then use data.aws_identitystore_group.platform_team.group_id in assignments.
#
# Until SCIM sync is done, assignments are managed via the console or added here
# after the first `tofu apply` with the real group IDs.

# Placeholder outputs so assignments can be wired once groups exist:
output "sso_instance_arn" {
  description = "IAM Identity Center instance ARN — needed to wire Entra SAML app."
  value       = local.sso_instance_arn
}

output "sso_identity_store_id" {
  description = "Identity store ID — used in SCIM provisioning URL."
  value       = local.sso_identity_store_id
}

output "permission_set_arns" {
  description = "Permission set ARNs — reference in account assignments."
  value = {
    administrator    = aws_ssoadmin_permission_set.administrator.arn
    developer        = aws_ssoadmin_permission_set.developer.arn
    readonly         = aws_ssoadmin_permission_set.readonly.arn
    security_auditor = aws_ssoadmin_permission_set.security_auditor.arn
  }
}
