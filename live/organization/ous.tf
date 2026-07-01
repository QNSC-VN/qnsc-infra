# ── Organizational Units (under the org root) ────────────────────────────────
# Security      → log-archive, security-audit (tamper-evident logging + detection)
# Infrastructure→ shared-services (ECR, CI, shared tooling)
# Workloads     → dev, staging, prod (Zone B commercial). Zone C med accounts
#                 will get their own OU when the hospital-AI track starts.
# Suspended     → parking OU for decommissioned accounts (tightest SCP).

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "suspended" {
  name      = "Suspended"
  parent_id = aws_organizations_organization.this.roots[0].id
}

locals {
  ou_id = {
    security       = aws_organizations_organizational_unit.security.id
    infrastructure = aws_organizations_organizational_unit.infrastructure.id
    workloads      = aws_organizations_organizational_unit.workloads.id
  }
}
