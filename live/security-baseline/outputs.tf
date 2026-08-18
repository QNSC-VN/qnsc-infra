output "audit_bucket_name" {
  value       = aws_s3_bucket.audit.id
  description = "S3 bucket holding CloudTrail + Config logs."
}

output "audit_kms_key_arn" {
  value       = aws_kms_key.audit.arn
  description = "CMK encrypting the audit logs."
}

output "cloudtrail_arn" {
  value       = aws_cloudtrail.org.arn
  description = "Account CloudTrail ARN."
}

output "guardduty_detector_id" {
  value       = aws_guardduty_detector.this.id
  description = "GuardDuty detector ID."
}

output "access_analyzer_arn" {
  value       = aws_accessanalyzer_analyzer.account.arn
  description = "Account IAM Access Analyzer ARN."
}

output "human_admin_role_arn" {
  value       = aws_iam_role.admin.arn
  description = "Assume with MFA for admin. Use as `role_arn` in ~/.aws/config."
}

output "human_developer_role_arn" {
  value       = aws_iam_role.developer.arn
  description = "Assume with MFA for read-only + SSM port-forwarding to the develop bastion."
}
