variable "bucket_name" {
  type        = string
  description = "S3 bucket name for shared build artifacts (e.g. qnsc-artifacts)"
}

variable "kms_key_arn" {
  type        = string
  default     = ""
  description = "KMS CMK ARN for SSE-KMS encryption. Leave empty to use AES256 (SSE-S3)."
}

variable "tags" {
  type    = map(string)
  default = {}
}
