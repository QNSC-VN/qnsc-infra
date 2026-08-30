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

output "alerting_prometheus_datasource_name" {
  value       = "grafanacloud-${grafana_cloud_stack.qnsc.slug}-prom"
  description = <<-EOT
    var.grafana_alerting.prometheus_datasource_name — Grafana Cloud's
    auto-provisioned Prometheus datasource name for this stack. A NAME, not
    a UID: looking up the UID needs a real `data` read against the Grafana
    instance API at PLAN time, which fails here on a fresh apply — the
    service account token that read would authenticate with doesn't exist
    yet in the SAME plan that creates it (data sources can't defer to apply
    the way resources can). `observability-alerts` resolves the UID itself,
    where its own provider config is always a plain, already-known CI
    secret value by the time any product applies — no such bootstrap
    ordering problem there.
  EOT
}

output "alerting_folder_uid" {
  value       = grafana_folder.alerts.uid
  description = "var.grafana_alerting.folder_uid — the shared folder every product's rule groups live under."
}

output "dashboards_folder_uid" {
  value       = grafana_folder.dashboards.uid
  description = "The PARENT folder for every product's own dashboards. Each product gets its own SUBFOLDER under this one (Grafana's nested-folder support, `parent_folder_uid`) — unlike alerting_folder_uid, which stays flat: dashboards multiply per product (Overview, Runtime, business KPIs) in a way a rule group per product never does, so a subfolder scales where a title-distinguished flat folder would get crowded."
}

output "rally_dashboards_folder_uid" {
  value       = grafana_folder.rally_dashboards.uid
  description = "Rally's dashboard subfolder — created ONCE here, not per-environment. See the resource's own comment for the real duplicate-folder bug this replaces."
}

output "opshub_dashboards_folder_uid" {
  value       = grafana_folder.opshub_dashboards.uid
  description = "Opshub's dashboard subfolder — created ONCE here, not per-environment. See rally_dashboards_folder_uid for the duplicate-folder bug this avoids from the start."
}

output "slos_folder_uid" {
  value       = grafana_folder.slos.uid
  description = "Shared SLOs folder, under the QNSC parent — pass to grafana_slo's folder_uid so a product's SLOs land here instead of Grafana's default SLO folder."
}
