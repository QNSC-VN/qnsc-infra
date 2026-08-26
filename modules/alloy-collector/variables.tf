variable "vpc_id" {
  description = "VPC the collector task runs in. Reuses runtime-dev's — this is a shared platform service, not a product."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets with NAT egress. cloudflared dials OUT; no inbound path is opened."
  type        = list(string)
}

variable "cluster_arn" {
  description = "ECS cluster to run the collector service in."
  type        = string
}

variable "kms_key_arn" {
  description = "Shared platform CMK — encrypts the task's log group and Secrets Manager entries."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the collector's own logs (not the telemetry it forwards)."
  type        = number
  default     = 14
}

# ── Cloudflare Tunnel ingress ─────────────────────────────────────────────────
# Same shape as every product's tunnel_enabled path: cloudflared sidecar dials out,
# so the task needs no ALB, no listener rule, no public IP, no inbound security
# group rule. Every product's OTLP exporter points at this tunnel's hostname.
variable "cloudflare_account_id" {
  description = "Cloudflare account id — creates the tunnel and its DNS record."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id for qnsc.vn — the tunnel's DNS record lives here."
  type        = string
}

variable "tunnel_hostname" {
  description = "Public hostname products send OTLP to, e.g. otel.qnsc.vn."
  type        = string
  default     = "otel.qnsc.vn"
}


# ── Grafana Cloud ──────────────────────────────────────────────────────────────
# One Cloud Access Policy token (stack-admin scope) is the ONLY credential that
# has to be created by hand — Grafana Cloud organizations aren't provisioned via
# API, so this is the one unavoidable manual step. Everything downstream of it
# (the stack itself, and the three per-signal push tokens Alloy uses) is
# provisioned by this module's parent, live/observability.
variable "prometheus_remote_write_url" {
  type = string
}
variable "prometheus_username" {
  type = string
}
variable "loki_url" {
  type = string
}
variable "loki_username" {
  type = string
}
variable "tempo_url" {
  type = string
}
variable "tempo_username" {
  type = string
}
variable "grafana_cloud_push_token" {
  description = "Single push token valid across Mimir/Loki/Tempo for this stack (Grafana Cloud access policy tokens are shared across the three)."
  type        = string
  sensitive   = true
}

# ── AWS CloudWatch bridge ───────────────────────────────────────────────────────
# Folds infra-level signal (ALB request count/latency/5xx, the two shared ALBs'
# own CloudWatch metrics) into the SAME Mimir the app-emitted OTel metrics land
# in — one store, one PromQL surface, instead of app metrics in Grafana Cloud and
# infra metrics staying siloed in CloudWatch's own console.
variable "alb_arns" {
  description = "Map of label => ALB ARN to scrape (e.g. { develop = ..., production = ... }). Both come from runtime-dev/runtime-prod's alb_arn output."
  type        = map(string)
}

variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  type    = number
  default = 1024
}

variable "tags" {
  type    = map(string)
  default = {}
}
