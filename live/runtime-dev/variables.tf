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

variable "enable_shared_cache" {
  type = bool
  # TRUE is the deployed setting: this stack has no .tfvars and CI passes no TF_VAR, so
  # the default IS the configuration. It is a variable rather than a hardcoded resource
  # only so the node can be removed in one line if the sharing arrangement is ever
  # unwound — not because anyone is expected to flip it.
  default     = true
  description = <<-EOT
    Create ONE Valkey node in this layer for every product's develop stack to share,
    replacing one cache.t4g.micro per product ($15.45/mo instead of $30.90).

    Products select it per stack; nothing here forces adoption. A product that sets
    `cache.shared = false` still gets its own node, which is the correct choice for
    anything that cannot tolerate sharing a server with another product.

    See module.shared_cache in main.tf for how database indexes and the eviction policy
    keep two products safe on one node — in particular that qnsc-kb runs Celery on it.
  EOT
}
