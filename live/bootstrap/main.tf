terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  # ── Bootstrap note ─────────────────────────────────────────────────────────
  # First-time setup is a two-step process (chicken-and-egg):
  #
  # Step 1: Run with local backend (default, no backend block):
  #   tofu init && tofu apply
  #   This creates the S3 bucket + DynamoDB table + GitHub OIDC provider.
  #
  # Step 2: Migrate state to the newly-created S3 bucket:
  #   Uncomment the s3 backend block below, then:
  #   tofu init -migrate-state
  #
  # After migration, all subsequent applies use the S3 backend.
  # ───────────────────────────────────────────────────────────────────────────

  # backend "s3" {
  #   bucket         = "qncs-tofu-state"
  #   key            = "platform/bootstrap/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   encrypt        = true
  #   dynamodb_table = "qncs-tofu-locks"
  # }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Org       = "qncs"
      ManagedBy = "opentofu"
      Layer     = "platform"
    }
  }
}

# ── Shared State Backend ──────────────────────────────────────────────────────
module "state_backend" {
  source         = "../../modules/state-backend"
  bucket_name    = "qncs-tofu-state"
  dynamodb_table = "qncs-tofu-locks"
  tags           = { Layer = "platform" }
}

# ── GitHub OIDC Provider ──────────────────────────────────────────────────────
# One per AWS account. Product infra repos reference this ARN via remote_state.
module "oidc_provider" {
  source = "../../modules/oidc-provider"
  tags   = { Layer = "platform" }
}
# ── Shared Customer-Managed KMS Key ────────────────────────────────────────────────────
# One CMK per account, alias/qncs-platform.
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
  bucket_name = "qncs-artifacts"
  kms_key_arn = module.kms.key_arn
  tags        = { Layer = "platform" }
}