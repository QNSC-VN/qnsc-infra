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

# Consumed by every product's infra for the `grafana` PROVIDER config that
# manages alert rules — a different credential from otlp_push above (see
# main.tf's "Alerting" header comment for why). Unlike the OTLP token, this
# one is needed at TERRAFORM PLAN/APPLY time, not just app runtime, so it
# reaches each product as a CI secret (e.g. `GRAFANA_ALERTS_TOKEN`), never
# through AWS Secrets Manager — nothing in a running task ever needs it.

output "alerting_grafana_url" {
  value       = grafana_cloud_stack.qnsc.url
  description = "var.grafana_alerting.url for every product's `grafana` provider block."
}

output "alerting_service_account_token" {
  value       = grafana_cloud_stack_service_account_token.alerting.key
  description = "Sensitive — read via `tofu output -raw` when populating a product's GRAFANA_ALERTS_TOKEN CI secret. Never write to AWS Secrets Manager: this credential has no reason to ever be reachable from inside a running ECS task."
  sensitive   = true
}

output "alerting_prometheus_datasource_uid" {
  value       = data.grafana_data_source.prometheus.uid
  description = "var.grafana_alerting.prometheus_datasource_uid — the Mimir datasource every product's alert rules query against."
}

output "alerting_folder_uid" {
  value       = grafana_folder.alerts.uid
  description = "var.grafana_alerting.folder_uid — the shared folder every product's rule groups live under."
}
