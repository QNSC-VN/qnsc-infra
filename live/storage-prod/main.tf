terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/storage-prod/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

# Cloudflare provider — reads the token from TF_VAR_cloudflare_api_token (or the
# CLOUDFLARE_API_TOKEN env var). Needs Account:Workers R2 Storage edit scope.
# Leave empty to skip provider auth (e.g. plan-only bootstrapping).
provider "cloudflare" {
  api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : null
}

# =============================================================================
# Shared object storage (prod) — Cloudflare R2 attachment buckets.
#
# Prod counterpart of storage-dev. Object storage is dedicated per-product; the
# buckets are provisioned here in the platform layer (where the Cloudflare
# provider + token already live for `edge`) so the R2 admin token is centralized
# in one stack rather than copied into every product's CI.
#
# Pins the Cloudflare provider v5 (R2 CORS/lifecycle are v5-only). Product stacks
# stay on v4 and consume the outputs via terraform_remote_state.
#
# NOTE: prod launch is gated — this stack is edited but NOT applied until launch.
# =============================================================================

module "rally_attachments" {
  count = var.cloudflare_account_id != "" ? 1 : 0

  source     = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/cf-r2?ref=cf-r2-v1.0.0"
  account_id = var.cloudflare_account_id
  name       = "rally-prod-attachments" # same name as the S3 bucket it replaces
  location   = "apac"                   # co-locate with the ap-southeast-1 footprint

  # Mirrors the rally-prod S3 CORS exactly (browser presigned PUT upload).
  cors_rules = [{
    allowed_methods = ["PUT"]
    allowed_origins = ["https://rally.qnsc.vn"]
    allowed_headers = ["Content-Type", "Content-Disposition"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }]
}

module "opshub_attachments" {
  count = var.cloudflare_account_id != "" ? 1 : 0

  # checkov:skip=CKV_TF_1: first-party module pinned by immutable release tag (matches rally_attachments) — not a mutable external source
  source     = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/cf-r2?ref=cf-r2-v1.0.0"
  account_id = var.cloudflare_account_id
  name       = "opshub-prod-attachments" # replaces the opshub-prod S3 uploads bucket
  location   = "apac"                    # co-locate with the ap-southeast-1 footprint

  # Mirrors the opshub-prod web origin (browser presigned PUT upload).
  cors_rules = [{
    allowed_methods = ["PUT"]
    allowed_origins = ["https://opshub.qnsc.vn"]
    allowed_headers = ["Content-Type", "Content-Disposition"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }]
}
