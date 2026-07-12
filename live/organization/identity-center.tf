# =============================================================================
# identity-center.tf — IAM Identity Center (SSO) permission sets.
#
# The human access model: people sign in through the Identity Center portal and
# assume a permission set in an account. No IAM users, no static keys, ever.
# CI/CD is unaffected (it keeps using GitHub OIDC roles from iam-oidc).
#
# Opt-in via enable_identity_center. The Identity Center INSTANCE must be enabled
# once in the console/CLI first (Organizations-backed); this stack then manages
# permission sets. Account *assignments* (which user/group gets which permission
# set in which account) need real principal IDs from your identity source, so
# they are intentionally left to a follow-up once users/groups exist — see
# README.md "Identity Center".
# =============================================================================

data "aws_ssoadmin_instances" "this" {
  count = var.enable_identity_center ? 1 : 0
}

locals {
  sso_instance_arn = var.enable_identity_center ? tolist(data.aws_ssoadmin_instances.this[0].arns)[0] : null

  # Permission sets → AWS managed policy attached. Least-privilege intent:
  #   admin     → break-glass / platform owner
  #   power     → engineers (everything except IAM/Org management)
  #   readonly   → auditors, dashboards
  #   billing   → finance
  permission_sets = {
    admin    = { description = "Full administrator (platform owner / break-glass).", managed_policy = "arn:aws:iam::aws:policy/AdministratorAccess", session = "PT4H" }
    power    = { description = "Engineer — everything except IAM/Org management.", managed_policy = "arn:aws:iam::aws:policy/PowerUserAccess", session = "PT8H" }
    readonly = { description = "Read-only auditor / dashboard access.", managed_policy = "arn:aws:iam::aws:policy/ReadOnlyAccess", session = "PT8H" }
    billing  = { description = "Finance — billing & cost management.", managed_policy = "arn:aws:iam::aws:policy/job-function/Billing", session = "PT4H" }
  }
}

resource "aws_ssoadmin_permission_set" "this" {
  for_each = var.enable_identity_center ? local.permission_sets : {}

  name             = "qnsc-${each.key}"
  description      = each.value.description
  instance_arn     = local.sso_instance_arn
  session_duration = each.value.session
  tags             = { Role = each.key }
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = var.enable_identity_center ? local.permission_sets : {}

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn
  managed_policy_arn = each.value.managed_policy
}
