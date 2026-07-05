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
module "iam_oidc" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/iam-oidc?ref=iam-oidc-v1.1.0"

  product           = "qnsc"
  oidc_provider_arn = module.oidc_provider.arn

  environments           = {}
  app_repo_names         = ["qnsc-infra"]
  infra_repo_name        = "qnsc-infra"
  ecr_repository_pattern = "qnsc-*"
  ecs_passrole_pattern   = "qnsc-*"
  tags                   = { Layer = "platform" }
}