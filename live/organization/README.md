# live/organization — AWS landing zone (Phase 1)

Creates the multi-account foundation from [PLATFORM_ARCHITECTURE §4](https://github.com/QNSC-VN/.github/blob/main/docs/PLATFORM_ARCHITECTURE.md) and the preventive guardrails from §10, as OpenTofu (no Control Tower). Runs in the **management account**.

## What it provisions

- **AWS Organization** (`feature_set = ALL`, SCPs enabled) + org-wide service access for CloudTrail/Config/GuardDuty/SecurityHub/Access-Analyzer/SSO (used by Phase 2).
- **OUs:** Security · Infrastructure · Workloads · Suspended.
- **Accounts:** `log-archive`, `security-audit` (Security OU) · `shared-services` (Infrastructure OU) · `dev`, `staging`, `prod` (Workloads OU). Management stays governance-only.
- **SCPs:** region-lock · protect-security-services · deny-root · deny-iam-users · require-IMDSv2.

## Prerequisites

1. **Bootstrap first.** `live/bootstrap` must have created the `qnsc-tofu-state` bucket + `qnsc-tofu-locks` table (this stack uses that S3 backend).
2. **Run as the management account** (admin creds / OIDC role in the org root).
3. **Unique root emails per account.** Provide via `account_emails`, or rely on plus-addressing `aws+<key>@qnsc.vn` (set `org_email_domain`). The inbox must be monitored (AWS sends root/billing mail there).
4. **If an Organization already exists** in this account, import it before apply:
   `tofu import aws_organizations_organization.this <o-xxxxxxxxxx>`

## Apply

```bash
cd live/organization
tofu init
tofu plan   -var 'org_email_domain=qnsc.vn'
tofu apply  -var 'org_email_domain=qnsc.vn'
```

Account creation takes a few minutes each. Outputs `account_ids` — downstream stacks (per-product VPC/ECS, the Phase-2 security baseline) assume `OrganizationAccountAccessRole` into these accounts via a provider `assume_role`.

## Not included (Phase 2 — after accounts exist)

GuardDuty / Security Hub / AWS Config / org CloudTrail → log-archive, delegated to the `security-audit` account, plus IAM Identity Center (SSO). These need the accounts from this phase to exist and use cross-account providers.
