# Consumed by every product's infra when wiring `var.observability.otlp_endpoint`
# (already-declared plumbing in modules/stack — see rally) and when populating
# the `observability-token` secret the observability-agent module reads.
#
# The token is deliberately NOT assembled into the final "Basic base64(...)"
# header here and is NOT written into any product's secret automatically —
# observability-agent's own README documents populating that secret out of
# band, on purpose, to keep the credential out of a product's Terraform state.
# This stack's job stops at handing over the two raw ingredients.

output "otlp_endpoint" {
  value       = grafana_cloud_stack.qnsc.otlp_url
  description = "var.observability.otlp_endpoint for every product's modules/stack call."
}

output "otlp_stack_id" {
  value       = grafana_cloud_stack.qnsc.id
  description = "Instance id half of the Basic auth pair — see observability-agent's README for the exact `aws secretsmanager put-secret-value` command."
}

output "otlp_push_token" {
  value       = grafana_cloud_access_policy_token.otlp_push.token
  description = "Token half of the Basic auth pair. Sensitive — read via `tofu output -raw` when populating a product's observability-token secret, never logged."
  sensitive   = true
}
