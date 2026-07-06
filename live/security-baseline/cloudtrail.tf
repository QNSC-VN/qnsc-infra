# ── CloudTrail — multi-region management-plane audit log ─────────────────────
# Immutable, validated, KMS-encrypted trail of every API call in the account.
resource "aws_cloudtrail" "org" {
  name           = "qnsc-account-trail"
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_key_prefix  = "cloudtrail"

  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.audit.arn

  # Capture management events on all resources (read + write).
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.audit]
}
