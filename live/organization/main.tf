terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  # Runs in the MANAGEMENT account. Requires bootstrap to have created the
  # state backend first (qnsc-infra/live/bootstrap). Then apply this stack.
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
  default_tags { tags = var.tags }
}

locals {
  # Accounts to vend under the Organization (management is the root, not vended).
  # key -> { name, ou }  ; email resolves from account_emails or plus-addressing.
  accounts = {
    log-archive     = { name = "qnsc-log-archive", ou = "security" }
    security-audit  = { name = "qnsc-security-audit", ou = "security" }
    shared-services = { name = "qnsc-shared-services", ou = "infrastructure" }
    dev             = { name = "qnsc-dev", ou = "workloads" }
    staging         = { name = "qnsc-staging", ou = "workloads" }
    prod            = { name = "qnsc-prod", ou = "workloads" }
  }

  account_email = {
    for k, v in local.accounts :
    k => lookup(var.account_emails, k, "aws+${k}@${var.org_email_domain}")
  }
}

# ── The Organization (all features: SCPs, consolidated billing, delegated admin)
# NOTE: if this management account is ALREADY in an organization, import it:
#   tofu import aws_organizations_organization.this o-xxxxxxxxxx
resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # Enable org-wide service access for the services the security baseline (Phase 2) uses.
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "guardduty.amazonaws.com",
    "securityhub.amazonaws.com",
    "access-analyzer.amazonaws.com",
    "sso.amazonaws.com",
  ]

  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]
}
