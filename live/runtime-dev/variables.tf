# This stack declares no input variables. The shared ALB's TLS certificate is
# the wildcard *.qnsc.vn cert produced by the edge stack, read in main.tf via
# terraform_remote_state — a single source of truth, so there is no per-env
# acm_cert_arn input to set.

variable "enable_alb" {
  type = bool
  # FALSE is the default, not just the current value: this stack has no .tfvars and CI
  # passes no TF_VAR for it, so the default IS the deployed setting. A default of true
  # would silently recreate the load balancer on the next apply.
  default     = false
  description = <<-EOT
    Create the shared ALB for develop. FALSE since 2026-08-02: rally's develop api
    serves through a Cloudflare Tunnel, leaving this load balancer with no target
    groups and no rules — $25.70/mo (hourly rate plus one public IPv4 per AZ) for
    nothing.

    Turning it off deletes the load balancer and its listeners only. The ACM
    certificate (edge stack) and the security group (module.network) survive, so
    recreating is minutes.
  EOT
}
