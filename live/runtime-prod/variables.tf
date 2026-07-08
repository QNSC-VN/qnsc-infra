variable "acm_cert_arn" {
  type        = string
  description = "ACM certificate ARN for the shared ALB HTTPS listener. Use a wildcard *.qnsc.vn cert covering every product API hostname routed on this ALB."
}

variable "tier" {
  type        = string
  default     = "lean"
  description = "Runtime reliability tier. lean = fck-nat single-AZ + one shared cache node (Version A ~$200). ha = NAT Gateway multi-AZ + flow logs, cache moves per-product (Version B)."
  validation {
    condition     = contains(["lean", "ha"], var.tier)
    error_message = "tier must be \"lean\" or \"ha\"."
  }
}

variable "rate_limit_per_5min" {
  type        = number
  default     = 3000
  description = "WAF per-IP request rate limit per 5-minute window on the shared ALB."
}
