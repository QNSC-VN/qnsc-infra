output "key_arn" {
  value       = aws_kms_key.this.arn
  description = "KMS CMK ARN — pass to RDS kms_key_id, Secrets Manager kms_key_id, S3 SSE config"
}

output "key_id" {
  value       = aws_kms_key.this.key_id
  description = "KMS CMK key ID"
}

output "key_alias" {
  value       = aws_kms_alias.this.name
  description = "KMS key alias (alias/qncs-platform)"
}
