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

variable "enable_alb" {
  type = bool
  # FALSE is the default, not merely the current value: this stack has no .tfvars and
  # CI passes no TF_VAR for it, so the default IS the deployed setting. A default of
  # true would silently recreate the load balancer on the next apply.
  default     = false
  description = <<-EOT
    Create the shared ALB for production. FALSE since 2026-08-02: rally's production
    api serves through a Cloudflare Tunnel, leaving this load balancer with no target
    groups and no rules — $29.35/mo (hourly rate plus one public IPv4 per AZ) for
    nothing.

    Set back to TRUE at go-live ONLY if rolling back off the tunnel, and before the
    product stack sets tunnel_enabled = false — a host-header rule cannot attach to a
    listener that does not exist. Restore enable_deletion_protection with it.
  EOT
}
