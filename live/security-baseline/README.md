# security-baseline

Account-wide audit & threat-detection baseline. Apply once per AWS account.

## What it creates

| Control | Resource | Purpose |
|---------|----------|---------|
| **CloudTrail** | `qnsc-account-trail` | Multi-region, log-file-validated, KMS-encrypted API audit log → `qnsc-audit-logs-<acct>/cloudtrail/` |
| **AWS Config** | recorder + delivery + 8 managed rules | Records all resource config → `.../config/`; flags public S3, unencrypted EBS/RDS, public RDS, IAM users with inline policies, missing CloudTrail, root-no-MFA |
| **GuardDuty** | detector | Continuous threat detection (+ S3 logs, EBS malware scan) |
| **Access Analyzer** | account analyzer | Flags resources shared outside the account |
| **Audit CMK** | `alias/qnsc-audit-logs` | Dedicated key for the log bucket (separate trust domain from the platform CMK) |

## Notes

- **Additive** — provisions no product resources, touches nothing bootstrap/products own.
- Log bucket is versioned, TLS-only (deny non-HTTPS), public-access-blocked, 7-year retention with IA/Glacier tiering.
- Uses its own CMK so it never has to modify the bootstrap key policy.

## Deploy

Via CI: the `apply-security-baseline` job in `.github/workflows/apply.yml` (gated by the **`security-baseline`** GitHub Environment — create it with a required reviewer). Runs on push to `main` touching `live/**`.

First-time note: AWS allows only **one** CloudTrail configuration recorder / Config recorder per region per account. If a manually-created trail or Config recorder already exists, import or remove it before the first apply.
