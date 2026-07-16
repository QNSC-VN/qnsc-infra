terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/bootstrap/terraform.tfstate"
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
    }
  }
}

locals {
  # Cloudflare IPv4 ranges (https://cloudflare.com/ips-v4). An external,
  # account-wide constant — every product that fronts its ALB with Cloudflare
  # locks ingress to these. Exported so a range change is ONE edit here, not N
  # copies across product prod stacks.
  cloudflare_ipv4 = [
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22",
    "103.31.4.0/22", "141.101.64.0/18", "108.162.192.0/18",
    "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22",
    "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
  ]
}

# ── Shared State Backend ──────────────────────────────────────────────────────
module "state_backend" {
  source         = "../../modules/state-backend"
  bucket_name    = "qnsc-tofu-state"
  dynamodb_table = "qnsc-tofu-locks"
  tags           = { Layer = "platform" }
}

# ── GitHub OIDC Provider ──────────────────────────────────────────────────────
# One per AWS account. Product infra repos reference this ARN via remote_state.
module "oidc_provider" {
  source = "../../modules/oidc-provider"
  tags   = { Layer = "platform" }
}
# ── Shared Customer-Managed KMS Key ────────────────────────────────────────────────────
# One CMK per account, alias/qnsc-platform.
# Used by: RDS (storage encryption), Secrets Manager, S3 SSE-KMS.
# Product infra reads the ARN from this stack's remote state.
module "kms" {
  source = "../../modules/kms"
  tags   = { Layer = "platform" }
}

# ── Shared Artifacts S3 Bucket ────────────────────────────────────────────────────────
# Central store for cross-repo build artifacts:
#   openapi/{product}/{env}/{sha}/openapi.json  ← immutable
#   openapi/{product}/{env}/latest/openapi.json ← mutable pointer
# Used by: rally-api CI (publish-openapi-spec action), rally-web CI (codegen).
module "artifacts_bucket" {
  source      = "../../modules/artifacts-bucket"
  bucket_name = "qnsc-artifacts"
  kms_key_arn = module.kms.key_arn
  tags        = { Layer = "platform" }
}

# ── GitHub OIDC — this repo's own infra-plan/infra-apply roles ──────────────
# plan.yml/apply.yml assume qnsc-github-infra-plan / qnsc-github-infra-apply.
# environments left empty — no per-environment app deploy role needed here
# (this repo only ever runs plan/apply, never deploys an app). app_repo_names
# can't be empty: the ecr-push role's trust policy needs at least one real
# repo in its condition or the policy is invalid; qnsc-infra never actually
# pushes images, so this role stays unused but harmless.
#
# NOTE: no infra_apply_guardrail here. This IS the platform stack that legitimately
# manages the state bucket / lock table / OIDC provider / CMK, so it must retain
# full control over them — the guardrail is for product applies (rally/opshub) that
# must never touch these foundations. v2.0.1 default infra_apply_subjects
# (environment:shared|develop|production) already match this repo's apply jobs.
module "iam_oidc" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/iam-oidc?ref=iam-oidc-v2.0.1"

  product           = "qnsc"
  oidc_provider_arn = module.oidc_provider.arn

  environments           = {}
  app_repo_names         = ["qnsc-infra"]
  infra_repo_name        = "qnsc-infra"
  ecr_repository_pattern = "qnsc-*"
  ecs_passrole_pattern   = "qnsc-*"
  tags                   = { Layer = "platform" }
}