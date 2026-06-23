output "state_bucket_name" {
  value       = module.state_backend.bucket_name
  description = "Use in all product infra backends: bucket = \"qncs-tofu-state\""
}

output "dynamodb_table_name" {
  value       = module.state_backend.table_name
  description = "Use in all product infra backends: dynamodb_table = \"qncs-tofu-locks\""
}

output "oidc_provider_arn" {
  value       = module.oidc_provider.arn
  description = "Pass to product infra iam-oidc modules to create deploy roles."
}
