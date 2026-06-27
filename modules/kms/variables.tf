variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to the KMS key and alias"
}
