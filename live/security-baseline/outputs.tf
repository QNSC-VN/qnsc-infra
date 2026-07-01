output "cloudtrail_bucket" {
  description = "S3 bucket name holding org CloudTrail logs (in log-archive account)."
  value       = aws_s3_bucket.cloudtrail.id
}

output "config_bucket" {
  description = "S3 bucket name holding AWS Config snapshots (in log-archive account)."
  value       = aws_s3_bucket.config.id
}

output "guardduty_detector_management" {
  description = "GuardDuty detector ID in management account."
  value       = aws_guardduty_detector.management.id
}

output "guardduty_detector_security_audit" {
  description = "GuardDuty detector ID in security-audit account (delegated admin)."
  value       = aws_guardduty_detector.security_audit.id
}

output "cloudtrail_kms_key_arn" {
  description = "KMS key ARN used to encrypt CloudTrail logs."
  value       = aws_kms_key.cloudtrail.arn
}
