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
  # checkov:skip=CKV_AWS_273: "Ensure access is controlled through SSO and not AWS IAM
  # defined users" — correct as a rule, and it is the rule this account followed until
  # 2026-08-18. It is not satisfiable here: Identity Center requires being an Organizations
  # MANAGEMENT account, and this account is now a MEMBER of a partner's org, so `aws sso
  # login` cannot exist. The header of this file has the full reasoning and the exit path
  # (federate the existing Entra tenant as a SAML provider). The mitigations that make this
  # tolerable are real, not paper: these users hold ZERO permissions, every privileged
  # action requires aws:MultiFactorAuthPresent, sessions last one hour, and CloudTrail
  # attributes each assumption. Re-evaluate this skip the day the account leaves that org.
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
    resources = [aws_iam_role.admin.arn, aws_iam_role.developer.arn, aws_iam_role.prod_breakglass.arn]
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

# Attached to a GROUP rather than to each user. Checkov's CKV_AWS_40 asks for this and it
# is right: one policy to review instead of one per person, and no way for two users to
# drift apart in what they may do. `&{aws:username}` still resolves per CALLER inside a
# group policy, so the self-service statements stay scoped to each person's own device.
resource "aws_iam_group" "humans" {
  name = "qnsc-humans"
}

resource "aws_iam_group_policy" "human_self_service" {
  name   = "self-service-and-assume-roles"
  group  = aws_iam_group.humans.name
  policy = data.aws_iam_policy_document.human_self_service.json
}

resource "aws_iam_user_group_membership" "humans" {
  for_each = aws_iam_user.human

  user   = each.value.name
  groups = [aws_iam_group.humans.name]
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

# THE POINT OF THIS ROLE. `AWS-StartPortForwardingSessionToRemoteHost` on a bastion is what
# lets a developer reach RDS and the cache from DBeaver without either being publicly
# accessible, without an SSH key, and without an inbound port. Access is decided by IAM
# rather than by the network, and every session lands in CloudTrail — the two properties an
# SSH bastion never had. The instance side was built in qnsc-infra#67 (nat_ssm_bastion).
#
# SCOPED BY THE `Environment` TAG, and that is a CORRECTION rather than a preference.
#
# This policy first shipped scoped by name — `ssm:resourceTag/Name` LIKE `*-nat-instance`.
# That pattern matches `qnsc-runtime-dev-nat-instance` AND
# `qnsc-runtime-prod-nat-instance`. It was harmless for exactly as long as production had
# no bastion, and #68 created one on 2026-08-18 for go-live. Verified with the policy
# simulator against the live production instance: `ssm:StartSession` returned ALLOWED.
# Nobody but the account owner held the role, so nothing was exposed — but the next
# developer or contractor added to `human_users` would have received production database
# access with no separate decision, no review, and nothing in the diff to show it.
#
# The `Environment` tag is the right discriminator because it is what actually
# distinguishes the two instances (`develop` vs `production`, set by each runtime stack's
# `tags`), and because it does not silently widen when a NAME changes. A future
# `qnsc-runtime-staging-nat-instance` is denied by default here rather than granted.
#
# BOTH CONDITIONS ARE REQUIRED, deliberately. The Environment tag decides WHICH instance and
# the document check decides WHAT KIND OF SESSION. Drop the second and this role can open an
# interactive SHELL on the bastion; drop the first and it reaches production.
#
# PRODUCTION IS A DIFFERENT ROLE, not a wider condition here — see qnsc-prod-breakglass
# below. Reaching real user data is a decision about a smaller group of people, and it
# should look like one in the code.
data "aws_iam_policy_document" "developer_ssm" {
  statement {
    sid       = "StartSessionOnDevelopBastionOnly"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = ["arn:${local.partition}:ec2:${data.aws_region.current.name}:${local.account_id}:instance/*"]

    # DEVELOP ONLY. Tag-scoped rather than pinned to an instance id, because the instance is
    # replaced by an apply or an AMI refresh and a hardcoded id would silently stop working
    # — but scoped by ENVIRONMENT, not by name, for the reason in the note above.
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Environment"
      values   = ["develop"]
    }

    # Refuses any document not granted below — this is what keeps it port-forwarding rather
    # than a shell.
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

  # Ending and reconnecting to your OWN session only. Without the condition a developer could
  # terminate somebody else's.
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

# ── Production data access: a separate role, a smaller group ─────────────────
# WHY THIS EXISTS AT ALL. Before it, there was NO path to the production database. Not a
# restricted one — none. RDS is not publicly accessible, ECS Exec is off, and until #68
# production had no bastion. That reads as safe and is actually the more dangerous state:
# the first time a user reports corrupted data, somebody under pressure reaches for
# `--publicly-accessible` or an over-broad security group rule, at 2am, with no audit trail.
# A designed door beats an improvised one.
#
# WHY IT IS NOT qnsc-developer. That role is held by developers and contractors, and it is
# the role a partner gets in order to use DBeaver against DEVELOP. Production holds real
# user data, so the group that may read it is smaller than the group that writes the code.
# Separating them means adding a contractor can never be the same act as granting them
# production access — the diff shows which list they went into.
#
# INERT UNTIL PRODUCTION HAS A BASTION. runtime-prod carries the NAT instance (#68, needed
# for egress at go-live) but `nat_ssm_bastion` is unset there, so no production instance has
# the SSM agent role and this policy has nothing to target. That is deliberate sequencing:
# the role is reviewed and merged first, and turning the door on is then a one-line, visible
# decision in qnsc-infra rather than something bundled with an IAM change.
#
# WHAT IT DOES NOT GRANT, and this is the part worth keeping: no shell (port-forwarding
# documents only, same as develop), and no secrets — `secretsmanager:GetSecretValue` is
# implicitly denied, verified with the policy simulator. So this role gets a NETWORK PATH to
# the database and nothing else. Somebody still has to hand over a credential out of band,
# which keeps "can reach it" and "can log in" two independent decisions, each revocable
# alone. Hand over a least-privilege role's password, never the RDS master.
#
# ONE-HOUR SESSIONS, which is AWS's FLOOR rather than a choice — `max_session_duration`
# rejects anything under 3600s, so a shorter break-glass window cannot be expressed here.
# Thirty minutes was the intent. If that matters, enforce it outside IAM: a session-duration
# alarm on CloudTrail, or simply terminating the port-forward when the query is done.
variable "breakglass_users" {
  type        = list(string)
  default     = ["qnsc-base"]
  description = <<-EOT
    Which of the `human_users` may reach the PRODUCTION database.

    Deliberately a separate list. Adding a developer or a contractor to `human_users` gives
    them develop; putting them here is a second, visible decision about real user data.

    Keep this as short as it can be — ideally the people who would be woken for an
    incident, and nobody else.
  EOT
}

data "aws_iam_policy_document" "assume_breakglass" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "AWS"
      identifiers = [
        for u in var.breakglass_users : "arn:${local.partition}:iam::${local.account_id}:user/${u}"
      ]
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "prod_breakglass" {
  name                 = "qnsc-prod-breakglass"
  description          = "Port-forward to the PRODUCTION bastion for incident diagnosis. No shell, no secrets, 1-hour sessions (AWS floor)."
  assume_role_policy   = data.aws_iam_policy_document.assume_breakglass.json
  max_session_duration = 3600
  tags                 = { ManagedBy = "opentofu", Purpose = "production-data-breakglass" }
}

# No ReadOnlyAccess here. qnsc-developer carries it because a developer needs to look around
# an environment; this role exists for one task, so it gets one permission. Anyone who needs
# to read production configuration already has qnsc-admin.
data "aws_iam_policy_document" "prod_breakglass_ssm" {
  statement {
    sid       = "StartSessionOnProductionBastionOnly"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = ["arn:${local.partition}:ec2:${data.aws_region.current.name}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Environment"
      values   = ["production"]
    }

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

  statement {
    sid       = "ManageOwnSessions"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:${local.partition}:ssm:*:*:session/&{aws:username}-*"]
  }
}

resource "aws_iam_role_policy" "prod_breakglass_ssm" {
  name   = "ssm-port-forward-to-production-bastion"
  role   = aws_iam_role.prod_breakglass.id
  policy = data.aws_iam_policy_document.prod_breakglass_ssm.json
}
