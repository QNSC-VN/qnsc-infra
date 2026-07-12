# organization

> AWS Organizations landing-zone root — the identity & governance foundation for
> the whole QNSC platform. Runs in the **management account** only.

This stack is the codified form of the **identity foundation** decision
(`COST_POSTURE_PLAN.md` §8–9, `ACCOUNT_SPLIT_PLAN.md` §1–2,
`DEPLOYMENT_AUDIT_GAPS.md` P0-1): adopt AWS Organizations + IAM Identity Center
(SSO) + baseline SCPs **now, single-account, at $0**. Only the dev/prod account
split and AWS Control Tower stay deferred.

## What it manages

| Resource | Why |
|---|---|
| `aws_organizations_organization` (feature set ALL) | enables SCPs + service delegation |
| OUs: `Security`, `Shared-Services`, `Workloads` | topology from `ACCOUNT_SPLIT_PLAN.md` §1 — empty today, attachment points ready for member accounts |
| SCPs (region-lock, deny-disable-logging, deny-leave-org, deny-iam-user-keys, deny-root) | free preventive guardrails |
| Identity Center permission sets (opt-in) | the human access model — SSO, no IAM users/keys |

Everything is **free**. The only AWS cost in this domain is AWS Config/GuardDuty,
which already lives in the `security-baseline` stack and its `COST_POSTURE` §3
line — not here.

## Cost & scope boundaries

- **CI/CD is untouched** — GitHub Actions keep using the OIDC roles from the
  `iam-oidc` module. No workflow, secret, or variable changes are required by
  this stack.
- **Product repos (`rally`, `opshub`) need no changes now.** They only change at
  the *actual* account split (per-env `AWS_ACCOUNT_ID`, per-account backends,
  cross-account ECR — see `ACCOUNT_SPLIT_PLAN.md` §4).

## Bootstrap runbook (one-time, management account)

Enabling Organizations and Identity Center are console/CLI actions that need
management-account admin credentials; Tofu then manages the OUs, SCPs, and
permission sets.

```bash
cd live/organization

# 1. Enable AWS Organizations (console → Organizations → "All features"),
#    OR let this stack create it. If it ALREADY exists, import instead of create:
tofu init
tofu import aws_organizations_organization.this <org-id>   # only if pre-existing

# 2. Wire the automation exemption + review, then apply the org + OUs + SCPs.
#    Start WITHOUT strict guardrails so you cannot lock out root before SSO:
tofu apply \
  -var 'logging_guardrail_exempt_role_arns=["arn:aws:iam::<acct>:role/qnsc-github-infra-apply"]'

# 3. Enable IAM Identity Center in the console (Organizations-backed), create
#    yourself an admin user, then manage permission sets here:
tofu apply -var 'enable_identity_center=true' -var '...'

# 4. Assign the admin permission set to your SSO user, sign in via the SSO
#    portal, and STOP using the root user.

# 5. Only AFTER an SSO admin path works, tighten the last guardrails:
tofu apply -var 'enforce_strict_guardrails=true' -var '...'
```

State key: `platform/organization/terraform.tfstate` (in `qnsc-tofu-state`).

## SCP safety (read before `enforce_strict_guardrails=true`)

- **region-lock** exempts all global services (IAM, STS, Organizations,
  CloudFront, Route 53, WAF/Shield, Identity Center, billing, support …) via the
  `NotAction` list, so it cannot brick the management account. `us-east-1` stays
  allowed for ACM-for-CloudFront and global-console operations. Adjust
  `allowed_regions` if the home region ever changes.
- **deny-disable-logging** exempts the ARNs in
  `logging_guardrail_exempt_role_arns` so `tofu apply` of the `security-baseline`
  stack still works. Set it to your `qnsc-github-infra-apply` role.
- **deny-root** and root-level **deny-iam-user-keys** are gated behind
  `enforce_strict_guardrails` (default `false`). Enable them **only after** an
  Identity Center admin permission set is assigned to a human — otherwise a
  denied root user with no non-root admin path = lockout.

## Identity Center

- Set `enable_identity_center = true` **after** the instance is enabled in the
  console. This stack creates the permission sets (`qnsc-admin`, `qnsc-power`,
  `qnsc-readonly`, `qnsc-billing`) and attaches AWS managed policies.
- **Account assignments** (which SSO user/group gets which permission set in
  which account) are intentionally not in this stack yet — they need real
  principal IDs from your identity source (Identity Center directory or external
  IdP). Add them once users/groups exist, ideally as a small `assignments.tf`
  keyed off `aws_identitystore_group` / `aws_identitystore_user` data sources.

## Forward path (deferred, documented in ACCOUNT_SPLIT_PLAN.md)

When the split trigger fires (first compliance customer / 2nd engineer): create
`dev` + `prod` member accounts under the `Workloads` OU and `shared-services`
under `Shared-Services` (Account Factory / `aws_organizations_account`), move the
region-lock + deny-iam-user-keys enforcement onto those OUs, and promote the
`security-baseline` CloudTrail to an org trail with delegated admin in the
`security` account. No rebuild — this stack is the groundwork.
