# =============================================================================
# organization — AWS Organizations landing-zone root (management account).
#
# The identity & governance foundation for the whole platform. Adopt NOW at $0,
# single-account — the account split (dev/prod member accounts) is deferred per
# COST_POSTURE_PLAN.md §8, but the free layer beneath it is not:
#   - AWS Organizations (feature set ALL) + service-access principals
#   - OUs matching the ACCOUNT_SPLIT_PLAN topology (Security / Shared-Services /
#     Workloads) — empty today, ready for member accounts at the split trigger
#   - Baseline Service Control Policies (region-lock, deny-disable-logging,
#     deny IAM-user/access-key creation, deny root, deny leave-org)
#   - IAM Identity Center (SSO) permission sets — the human access model
#     (opt-in via enable_identity_center; humans use SSO, never IAM users/keys)
#
# Additive & isolated: provisions no product resources, owns nothing the
# bootstrap / security-baseline / product stacks own. This stack runs in the
# MANAGEMENT account only.
#
# ⚠ Bootstrap order & import: enabling Organizations + Identity Center is a
# one-time console/CLI action (needs management-account admin). If the org
# already exists, import it before the first apply:
#     tofu import aws_organizations_organization.this <org-id>
# See README.md for the full runbook and the SCP lockout-safety notes.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/organization/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Org       = "qnsc"
      ManagedBy = "opentofu"
      Layer     = "platform"
      Stack     = "organization"
    }
  }
}

# ── The organization ──────────────────────────────────────────────────────────
# feature_set = ALL is required for SCPs. Service-access principals let the org
# delegate/aggregate the services we already run (CloudTrail org trail, Config,
# GuardDuty, Access Analyzer) and the identity layer (Identity Center / SSO).
resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  aws_service_access_principals = [
    "sso.amazonaws.com",             # IAM Identity Center
    "cloudtrail.amazonaws.com",      # org-wide trail (future delegated admin)
    "config.amazonaws.com",          # org-wide Config aggregation
    "guardduty.amazonaws.com",       # org-wide threat detection
    "access-analyzer.amazonaws.com", # org-wide external-access findings
    "account.amazonaws.com",         # alternate contacts / account mgmt
  ]

  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]
}

# ── Organizational Units (topology from ACCOUNT_SPLIT_PLAN.md §1) ──────────────
# Empty today (single account). Created now so the tree + SCP attachment points
# exist before member accounts land — the split becomes an Account-Factory move,
# not a re-org. The management account stays at the root (never inside an OU).
resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "shared_services" {
  name      = "Shared-Services"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.this.roots[0].id
}

locals {
  root_id = aws_organizations_organization.this.roots[0].id
}
