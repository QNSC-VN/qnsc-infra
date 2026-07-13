# The shared ALB's TLS certificate is the wildcard *.qnsc.vn cert produced by the
# edge stack, read in main.tf via terraform_remote_state (single source of truth)
# — there is no acm_cert_arn input to set per environment.

variable "rate_limit_per_5min" {
  type        = number
  default     = 3000
  description = "WAF per-IP request rate limit per 5-minute window on the shared ALB."
}

variable "enable_aws_waf" {
  type        = bool
  default     = false
  description = "Attach the AWS WAFv2 WebACL to the shared ALB. OFF by default: Cloudflare edge owns the WAF (rate-limit + custom rules free-tier; managed OWASP at Pro+ via the edge stack's enable_managed_waf) — see COST_POSTURE_PLAN §10, never run both. Turn ON only for origin-side defense-in-depth."
}
