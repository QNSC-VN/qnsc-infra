# Consumed by the rally product stacks via terraform_remote_state
# (platform/storage-prod) — injected into the api/worker tasks as
# S3_ATTACHMENTS_BUCKET + STORAGE_ENDPOINT. null when the stack is applied
# plan-only (no cloudflare_account_id).
output "rally_attachments_name" {
  value       = one(module.rally_attachments[*].name)
  description = "rally-prod R2 attachments bucket name (inject as S3_ATTACHMENTS_BUCKET)."
}

output "rally_attachments_endpoint" {
  value       = one(module.rally_attachments[*].endpoint)
  description = "rally-prod R2 S3-compatible API endpoint (inject as STORAGE_ENDPOINT)."
}

# Consumed by the opshub product stacks via terraform_remote_state
# (platform/storage-prod) — injected into the api/worker tasks as
# S3_ATTACHMENTS_BUCKET + STORAGE_ENDPOINT. null when applied plan-only.
output "opshub_attachments_name" {
  value       = one(module.opshub_attachments[*].name)
  description = "opshub-prod R2 attachments bucket name (inject as S3_ATTACHMENTS_BUCKET)."
}

output "opshub_attachments_endpoint" {
  value       = one(module.opshub_attachments[*].endpoint)
  description = "opshub-prod R2 S3-compatible API endpoint (inject as STORAGE_ENDPOINT)."
}

# Consumed by ceo-suite CI (web-deploy `d1_backup_bucket`) — durable archive of
# pre-migration D1 exports. null when applied plan-only (no cloudflare_account_id).
output "ceo_suite_db_backups_name" {
  value       = one(module.ceo_suite_db_backups[*].name)
  description = "ceo-suite D1 backup R2 bucket name (set as web-deploy d1_backup_bucket)."
}
