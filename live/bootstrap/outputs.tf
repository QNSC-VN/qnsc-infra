output "state_bucket_name" {
  value       = module.state_backend.bucket_name
  description = "Use in all product infra backends: bucket = \"qnsc-tofu-state\""
}

output "dynamodb_table_name" {
  value       = module.state_backend.table_name
  description = "Use in all product infra backends: dynamodb_table = \"qnsc-tofu-locks\""
}

output "oidc_provider_arn" {
  value       = module.oidc_provider.arn
  description = "GitHub OIDC provider ARN — discovered automatically by product infra via data source"
}

output "kms_key_arn" {
  value       = module.kms.key_arn
  description = "Shared CMK ARN — pass to RDS kms_key_id, Secrets Manager kms_key_id, S3 SSE"
}

output "kms_key_alias" {
  value       = module.kms.key_alias
  description = "KMS key alias (alias/qnsc-platform)"
}

output "artifacts_bucket_name" {
  value       = module.artifacts_bucket.bucket_name
  description = "Shared artifacts bucket name — use as s3-bucket in publish-openapi-spec CI action"
}

output "artifacts_bucket_arn" {
  value       = module.artifacts_bucket.bucket_arn
  description = "Shared artifacts bucket ARN — grant product IAM roles write access to their prefix"
}
