# Security Policy

## Reporting a Vulnerability

**Do not open a public GitHub issue.**

Email: **security@qnsc.vn**

Acknowledgement within **48 hours**, status update within **7 days**.

## Scope

**In scope:**
- IAM over-permissive policies (especially the OIDC provider and infra roles)
- S3 state bucket misconfiguration (public access, missing encryption)
- Hardcoded credentials in Tofu code or state files
- GitHub OIDC subject constraint bypass

**Out of scope:**
- Issues requiring physical AWS data-centre access

## Practices

- GitHub OIDC is used — no long-lived AWS keys in CI/CD
- S3 state bucket is private, versioned, and AES-256 encrypted
- DynamoDB state locking prevents concurrent applies
- All applies to bootstrap require manual approval via GitHub Environments
- Changes are reviewed by at least one CODEOWNERS member before merge
