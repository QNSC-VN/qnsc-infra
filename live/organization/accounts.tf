# ── Member accounts ───────────────────────────────────────────────────────────
# Vended into their OU. The management (root) account is NOT created here — it is
# the account this stack runs in and must hold NO workloads (governance only).
#
# Each account gets an OrganizationAccountAccessRole (default) assumable from the
# management account — that is how downstream per-account stacks (VPC, ECS, the
# Phase-2 security baseline) authenticate via provider assume_role.
#
# NOTE: `email` and `name` are effectively immutable after creation. Closing an
# account via OpenTofu is intentionally guarded — removal requires manual steps.

resource "aws_organizations_account" "this" {
  for_each = local.accounts

  name      = each.value.name
  email     = local.account_email[each.key]
  parent_id = local.ou_id[each.value.ou]

  # Keep the account when removed from config (avoid accidental closure);
  # close deliberately via the console/CLI if ever needed.
  close_on_deletion = false

  # Role name assumed from the management account into the member account.
  role_name = "OrganizationAccountAccessRole"

  lifecycle {
    # Root email / name changes require account recreation — block that by mistake.
    ignore_changes = [role_name]
  }

  tags = merge(var.tags, { Account = each.value.name, Env = each.key })
}
