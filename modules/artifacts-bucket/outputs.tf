output "bucket_name" {
  value       = aws_s3_bucket.artifacts.bucket
  description = "Artifacts bucket name — pass as s3-bucket to publish-openapi-spec action"
}

output "bucket_arn" {
  value       = aws_s3_bucket.artifacts.arn
  description = "Artifacts bucket ARN — use in IAM policies to grant product write access"
}
