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
    # x-amz-checksum-sha256 is REQUIRED: the presigned PUT binds the SHA-256 into
    # its signature, so the browser must be allowed to send that header or every
    # upload fails at preflight.
    allowed_headers = ["Content-Type", "Content-Disposition", "x-amz-checksum-sha256"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }]

  # Incomplete multipart uploads are invisible in a bucket listing but still
  # billed. Nothing else reaps them — the app-side reaper only knows about keys
  # it has a DB row for, and an aborted multipart never produced one.
  # TODO(cdn): attach `custom_domain` here once cf-r2-v1.1.0 is tagged, then bump
  # the ref above and wire the module's `public_base_url` output into the product
  # stack as CDN_PUBLIC_ASSETS_BASE_URL. Until then public assets fall back to a
  # presigned GET — correct, just not edge-cached. Nothing consumes them yet.
  lifecycle_rules = [{
    id                              = "abort-incomplete-multipart"
    abort_incomplete_multipart_days = 7
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
    # x-amz-checksum-sha256 is REQUIRED: the presigned PUT binds the SHA-256 into
    # its signature, so the browser must be allowed to send that header or every
    # upload fails at preflight.
    allowed_headers = ["Content-Type", "Content-Disposition", "x-amz-checksum-sha256"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }]

  # Incomplete multipart uploads are invisible in a bucket listing but still
  # billed. Nothing else reaps them — the app-side reaper only knows about keys
  # it has a DB row for, and an aborted multipart never produced one.
  lifecycle_rules = [{
    id                              = "abort-incomplete-multipart"
    abort_incomplete_multipart_days = 7
  }]
}

# ── Public assets ─────────────────────────────────────────────────────────────
# Separate bucket, deliberately. Avatars and workspace logos need long-lived,
# cacheable, CDN-servable URLs; attachments need short-lived signed ones. Putting
# both in one bucket means either attachments become CDN-readable by key
# (bypassing every authorization check) or avatars cannot be cached at all.
#
# Nothing sensitive belongs here: everything in this bucket is readable by anyone
# who knows the key. The app enforces that via UploadPolicy.visibility — only
# raster-image, non-sensitive surfaces may target it.
module "rally_public_assets" {
  count = var.cloudflare_account_id != "" ? 1 : 0

  # checkov:skip=CKV_TF_1: first-party module pinned by immutable release tag
  source     = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/cf-r2?ref=cf-r2-v1.0.0"
  account_id = var.cloudflare_account_id
  name       = "rally-prod-public-assets"
  location   = "apac"

  cors_rules = [{
    allowed_methods = ["PUT"]
    allowed_origins = ["https://rally.qnsc.vn"]
    allowed_headers = ["Content-Type", "Content-Disposition", "x-amz-checksum-sha256"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }]

  lifecycle_rules = [{
    id                              = "abort-incomplete-multipart"
    abort_incomplete_multipart_days = 7
  }]
}
