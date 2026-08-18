# =============================================================================
# human-access.tf — how PEOPLE reach this account.
#
# WHY THIS FILE EXISTS. This account was the management account of its own AWS
# Organization and used IAM Identity Center: humans ran `aws sso login`, nobody held
# long-lived keys, and live/organization/main.tf recorded the rule as "humans use SSO,
# never IAM users/keys".
#
# On 2026-08-18 the organization was deleted so the account could join a partner's org to
# evaluate Kiro. An account belongs to at most one organization, so deleting ours was the
# only route in — and Identity Center lives in the management account, so it went with it.
# A MEMBER account cannot enable Identity Center. `aws sso login` is therefore gone, and
# it is not coming back while this account is a member of someone else's org.
#
# WHAT DID NOT BREAK, because it is the reason there was no outage: GitHub Actions
# authenticates through the OIDC provider in iam-oidc, not through Identity Center. All 13
# github roles kept working throughout — verified by a Terraform plan that ran and read
# state after the org was deleted. Machine access needs nothing from this file.
#
# THE SHAPE THIS RESTORES, as close to the old rule as a member account allows:
#
#   qnsc-base            an IAM user per human, holding NO permissions. It exists only to
#                        prove who you are and to carry an MFA device. Its access keys are
#                        worthless alone: every statement below requires MFA.
#   qnsc-admin           AdministratorAccess, assumed with MFA, credentials expire.
#   qnsc-developer       ssm:StartSession on the bastion + read-only. This is the
#                        "developers can reach the develop database" access that was
#                        scoped as an Identity Center permission set and never built.
#
# So no human holds a standing privilege. The keys grant nothing; the roles grant
# everything and only for an hour at a time, only with MFA, and every assumption lands in
# CloudTrail.
#
# THE HONEST GAP. This is weaker than Identity Center in one way that matters: there is no
# central directory. Removing someone means deleting their IAM user HERE, not removing
# them from a group in Entra. With one or two admins that is fine. Past a handful of
# people, federate Entra ID directly to IAM as a SAML provider — the tenant already exists
# and already backs the applications (entra_tenant_id in the product stacks), so the
# people are already there. Treat this file as the bootstrap, not the destination.
#
# ROOT stays the break-glass and is already correct: MFA assigned 2026-07-12, zero access
# keys, no CloudFront key pairs, no X.509 certificates. Root is currently the ONLY other
# way in, so it holds a single point of failure worth removing — assign a SECOND MFA
# device and keep it somewhere else physically.
# =============================================================================

# ── The identity: one user per human, no permissions ─────────────────────────
# `force_destroy` so removing a leaver does not fail on their attached MFA device or keys.
resource "aws_iam_user" "human" {
  for_each = toset(var.human_users)

  name          = each.key
  force_destroy = true
  tags          = { ManagedBy = "opentofu", Purpose = "human-identity-no-privileges" }
}

# Self-service MFA, and NOTHING else that is not MFA-gated.
#
# The two statements are deliberately split. A user with no MFA device yet must be able to
# enrol one, and that call cannot itself require MFA or nobody could ever start. So
# `AllowManageOwnMFA` is ungated but scoped to the caller's OWN user path — ${aws:username}
# means it cannot touch anyone else's device. Everything with real power sits under
# `AllowAssumeRolesWithMFA`, which does require it.
data "aws_iam_policy_document" "human_self_service" {
  statement {
    sid    = "AllowManageOwnMFA"
    effect = "Allow"
    actions = [
      "iam:CreateVirtualMFADevice",
      "iam:EnableMFADevice",
      "iam:ResyncMFADevice",
      "iam:ListMFADevices",
      "iam:DeleteVirtualMFADevice",
      "iam:ChangePassword",
      "iam:GetUser",
      "iam:CreateAccessKey",
      "iam:ListAccessKeys",
      "iam:UpdateAccessKey",
      "iam:DeleteAccessKey",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:user/&{aws:username}",
      "arn:${local.partition}:iam::${local.account_id}:mfa/&{aws:username}",
    ]
  }

  statement {
    sid       = "AllowListForConsole"
    effect    = "Allow"
    actions   = ["iam:ListVirtualMFADevices", "iam:ListUsers", "iam:ListAccountAliases"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowAssumeRolesWithMFA"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.admin.arn, aws_iam_role.developer.arn]
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_user_policy" "human_self_service" {
  for_each = aws_iam_user.human

  name   = "self-service-and-assume-roles"
  user   = each.value.name
  policy = data.aws_iam_policy_document.human_self_service.json
}

# ── Trust: only these users, only with MFA, one-hour sessions ───────────────
data "aws_iam_policy_document" "assume_by_humans" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [for u in aws_iam_user.human : u.arn]
    }

    # Without this a leaked access key IS the role. With it the key is useless on its own.
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "admin" {
  name                 = "qnsc-admin"
  description          = "Full admin, assumed with MFA. Replaces the deleted Identity Center AdministratorAccess permission set."
  assume_role_policy   = data.aws_iam_policy_document.assume_by_humans.json
  max_session_duration = 3600
  tags                 = { ManagedBy = "opentofu" }
}

resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.admin.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

# ── Developer: reach the develop database, and nothing else ──────────────────
resource "aws_iam_role" "developer" {
  name                 = "qnsc-developer"
  description          = "Read-only plus SSM port-forwarding to the bastion, for reaching the develop RDS and cache from a laptop."
  assume_role_policy   = data.aws_iam_policy_document.assume_by_humans.json
  max_session_duration = 3600
  tags                 = { ManagedBy = "opentofu" }
}

resource "aws_iam_role_policy_attachment" "developer_readonly" {
  role       = aws_iam_role.developer.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

# THE POINT OF THIS ROLE. `AWS-StartPortForwardingSessionToRemoteHost` on the NAT/bastion
# instance is what lets a developer reach RDS and the cache from DBeaver without either
# being publicly accessible, without an SSH key, and without an inbound port. Access is
# decided by IAM rather than by the network, and every session is in CloudTrail — the two
# properties an SSH bastion never had. The instance side was built in qnsc-infra#67
# (nat_ssm_bastion); this is the human side, which was scoped as an Identity Center
# permission set and never created.
#
# TWO STATEMENTS, and both are required — this is the shape AWS documents and it is easy to
# get wrong. Granting the instance without the document lets a caller open an interactive
# SHELL on the bastion; granting the document without the instance denies everything.
#
# DEVELOP ONLY, by construction rather than by intent: runtime-prod leaves
# nat_ssm_bastion unset, so no production instance carries the SSM role and there is
# nothing here to target. Reaching the production database this way is a deliberate change
# to that stack, not a permission handed out here.
data "aws_iam_policy_document" "developer_ssm" {
  statement {
    sid       = "StartSessionOnBastionInstancesOnly"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = ["arn:${local.partition}:ec2:${data.aws_region.current.name}:${local.account_id}:instance/*"]

    # The bastion is the fck-nat instance, named `<stack>-nat-instance` by the network
    # module. Tag-scoped rather than pinned to an instance id: the instance is replaced by
    # an apply or an AMI refresh and a hardcoded id would silently stop working.
    condition {
      test     = "StringLike"
      variable = "ssm:resourceTag/Name"
      values   = ["*-nat-instance"]
    }

    # Refuses any document not granted below — this is what keeps it port-forwarding
    # rather than a shell.
    condition {
      test     = "BoolIfExists"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }
  }

  statement {
    sid     = "PortForwardingDocumentsOnly"
    effect  = "Allow"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:${local.partition}:ssm:${data.aws_region.current.name}::document/AWS-StartPortForwardingSessionToRemoteHost",
      "arn:${local.partition}:ssm:${data.aws_region.current.name}::document/AWS-StartPortForwardingSession",
    ]
  }

  # Ending and reconnecting to your OWN session only. Without the condition a developer
  # could terminate somebody else's.
  statement {
    sid       = "ManageOwnSessions"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:${local.partition}:ssm:*:*:session/&{aws:username}-*"]
  }
}

resource "aws_iam_role_policy" "developer_ssm" {
  name   = "ssm-port-forward-to-bastion"
  role   = aws_iam_role.developer.id
  policy = data.aws_iam_policy_document.developer_ssm.json
}
