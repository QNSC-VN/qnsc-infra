# Consumed by the rally product stacks via terraform_remote_state
# (platform/storage-dev) — injected into the api/worker tasks as
# S3_ATTACHMENTS_BUCKET + STORAGE_ENDPOINT. null when the stack is applied
# plan-only (no cloudflare_account_id).
output "rally_attachments_name" {
  value       = one(module.rally_attachments[*].name)
  description = "rally-develop R2 attachments bucket name (inject as S3_ATTACHMENTS_BUCKET)."
}

output "rally_attachments_endpoint" {
  value       = one(module.rally_attachments[*].endpoint)
  description = "rally-develop R2 S3-compatible API endpoint (inject as STORAGE_ENDPOINT)."
}

# Consumed by the opshub product stacks via terraform_remote_state
# (platform/storage-dev) — injected into the api/worker tasks as
# S3_ATTACHMENTS_BUCKET + STORAGE_ENDPOINT. null when applied plan-only.
output "opshub_attachments_name" {
  value       = one(module.opshub_attachments[*].name)
  description = "opshub-develop R2 attachments bucket name (inject as S3_ATTACHMENTS_BUCKET)."
}

output "opshub_attachments_endpoint" {
  value       = one(module.opshub_attachments[*].endpoint)
  description = "opshub-develop R2 S3-compatible API endpoint (inject as STORAGE_ENDPOINT)."
}

output "rally_public_assets_name" {
  value       = one(module.rally_public_assets[*].name)
  description = "rally-develop R2 public-assets bucket name (inject as S3_PUBLIC_ASSETS_BUCKET)."
}

output "rally_public_assets_base_url" {
  value       = one(module.rally_public_assets[*].public_base_url)
  description = <<-EOT
    Public HTTPS origin for rally-develop public assets — inject as
    CDN_PUBLIC_ASSETS_BASE_URL. Null until `custom_domain` is attached, and the API
    returns 409 on every avatar upload while it is null.

    ONLY ever from the public-assets bucket. This origin serves objects to anyone
    who knows the key, so wiring it from an attachments bucket would silently make
    every permission-gated file world-readable.
  EOT
}
