# live/security-baseline — Phase 2

Org-wide security controls. Requires Phase 1 (`live/organization`) applied first — you need the account IDs from its outputs.

## What it provisions

| Component | Where | Notes |
|-----------|-------|-------|
| Org CloudTrail | management → log-archive S3 | KMS-encrypted, 7-year retention, all regions |
| GuardDuty | management + delegated to security-audit | S3/K8s/EBS/malware protection enabled |
| Security Hub | management + delegated to security-audit | CIS v1.4 + FSBP standards |
| IAM Access Analyzer | management | org-wide, flags overly permissive cross-account policies |
| AWS Config | security-audit + delivery to log-archive S3 | 5 baseline managed rules |
| IAM Identity Center | management | 4 permission sets; Entra ID federation via runbook below |

## Prerequisites

1. Phase 1 applied — have `account_ids` output ready.
2. **IAM Identity Center enabled** in the management account (Console → IAM Identity Center → Enable). This is a one-click action; not yet supported as an OpenTofu resource (it's a data source only).
3. Management account creds with `organizations:*` + `sso:*` + `guardduty:*` etc.

## Apply

```bash
cd live/security-baseline
tofu init

tofu plan \
  -var 'security_audit_account_id=<ACCOUNT_ID>' \
  -var 'log_archive_account_id=<ACCOUNT_ID>' \
  -var 'org_id=<o-xxxxxxxxxx>' \
  -var 'org_root_id=<r-xxxx>'

tofu apply \
  -var 'security_audit_account_id=<ACCOUNT_ID>' \
  -var 'log_archive_account_id=<ACCOUNT_ID>' \
  -var 'org_id=<o-xxxxxxxxxx>' \
  -var 'org_root_id=<r-xxxx>'
```

Get the values from Phase 1 outputs:
```bash
cd ../organization
tofu output
```

## Microsoft Entra ID → IAM Identity Center federation (SSO)

Your company uses M365 → Microsoft Entra ID (Azure AD) is your IdP. Once `tofu apply` completes, wire SSO in ~15 min:

### Step 1 — Get IAM Identity Center metadata

From `tofu output` after apply:
- `sso_instance_arn` — the ARN of your Identity Center instance
- `sso_identity_store_id` — used for SCIM endpoint URL

AWS console: **IAM Identity Center → Settings → Identity source tab**
- Copy the **SAML metadata XML download URL** (you'll upload this to Entra)
- Copy the **SCIM endpoint URL** + generate an **Access token** (save it — shown once)

### Step 2 — Register app in Microsoft Entra portal

1. Go to [portal.azure.com](https://portal.azure.com) → **Microsoft Entra ID → Enterprise applications → New application**
2. Search for **"AWS IAM Identity Center"** (official gallery app) → Add
3. In the app → **Single sign-on → SAML**:
   - Upload the SAML metadata XML downloaded from Step 1
   - Entra auto-populates the ACS URL and Entity ID
4. In the app → **Provisioning → Automatic**:
   - Paste the SCIM endpoint URL and Access token from Step 1
   - Set provisioning mode to **Automatic**
   - Test connection → Start provisioning

### Step 3 — Assign groups in Entra

Create groups in Entra (or use existing):
- `AWS-PlatformTeam` → AdministratorAccess permission set
- `AWS-Developers` → DeveloperAccess permission set
- `AWS-ReadOnly` → ReadOnlyAccess permission set

Assign these groups to the AWS IAM Identity Center enterprise app in Entra.
SCIM will push them to IAM Identity Center within minutes.

### Step 4 — Wire account assignments in OpenTofu

After SCIM sync, groups appear in IAM Identity Center. Get their IDs:
```bash
aws identitystore list-groups \
  --identity-store-id <sso_identity_store_id>
```

Then add to `sso.tf`:
```hcl
data "aws_identitystore_group" "platform_team" {
  identity_store_id = local.sso_identity_store_id
  filter {
    attribute_path  = "DisplayName"
    attribute_value = "AWS-PlatformTeam"
  }
}

resource "aws_ssoadmin_account_assignment" "platform_team_prod" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.administrator.arn
  principal_type     = "GROUP"
  principal_id       = data.aws_identitystore_group.platform_team.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = "<prod_account_id>"
}
```

Run `tofu apply` again to push the assignments.

### Result

Team members log into [https://qnsc.awsapps.com/start](https://qnsc.awsapps.com/start) with their **qnsc.vn Microsoft credentials**. No separate AWS passwords. CLI: `aws sso login --profile <profile>`.

## Not included (future)

- Macie (S3 sensitive data scanning) — add when staging data lake exists
- Inspector v2 (EC2/container vuln scanning) — add when ECS services are deployed
- AWS Backup org-wide policy — add at production stage
- Security Hub custom actions / EventBridge → PagerDuty — add when on-call rotation needed
