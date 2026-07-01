terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  # Runs in the MANAGEMENT account. Requires Phase 1 (organization stack) applied first.
  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/security-baseline/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

# ── Providers ──────────────────────────────────────────────────────────────────
# Default: management account (ap-southeast-1)
provider "aws" {
  region = "ap-southeast-1"
  default_tags { tags = var.tags }
}

# Cross-account into security-audit — delegated admin for GuardDuty / SecurityHub / Config
provider "aws" {
  alias  = "security_audit"
  region = "ap-southeast-1"
  assume_role {
    role_arn = "arn:aws:iam::${var.security_audit_account_id}:role/OrganizationAccountAccessRole"
  }
  default_tags { tags = var.tags }
}

# Cross-account into log-archive — owns the S3 buckets that CloudTrail/Config write to
provider "aws" {
  alias  = "log_archive"
  region = "ap-southeast-1"
  assume_role {
    role_arn = "arn:aws:iam::${var.log_archive_account_id}:role/OrganizationAccountAccessRole"
  }
  default_tags { tags = var.tags }
}

# ── Data sources (read-only, no drift) ─────────────────────────────────────────
data "aws_caller_identity" "management" {}
data "aws_region" "current" {}
