variable "org_email_domain" {
  description = "Email domain for account root addresses (e.g. qnsc.vn). Account emails are formed as aws+<account>@<domain> unless overridden in account_emails."
  type        = string
  default     = "qnsc.vn"
}

# Each AWS account requires a UNIQUE root email. Use plus-addressing on a single
# monitored inbox (aws+log-archive@qnsc.vn, …) or a distribution list per account.
# Override any of these explicitly if you don't use plus-addressing.
variable "account_emails" {
  description = "Map of account key -> root email. Missing keys fall back to aws+<key>@<org_email_domain>."
  type        = map(string)
  default     = {}
}

variable "approved_regions" {
  description = "Regions workloads may operate in. The region-lock SCP denies actions elsewhere (global services excepted)."
  type        = list(string)
  default     = ["ap-southeast-1", "us-east-1"] # us-east-1 kept for global services (CloudFront/ACM/IAM)
}

variable "tags" {
  description = "Base tags applied to Organizations resources."
  type        = map(string)
  default = {
    Org       = "qnsc"
    ManagedBy = "opentofu"
    Layer     = "landing-zone"
  }
}
