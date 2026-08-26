# Consumed by every product's infra/live/{develop,prod}/main.tf via
# terraform_remote_state, one new observability_endpoint-shaped input on
# modules/stack — see the implementation plan in the reference design doc.

output "otlp_endpoint" {
  value       = "https://${module.alloy.tunnel_hostname}"
  description = "OTEL_EXPORTER_OTLP_ENDPOINT for every product's api/worker task."
}

output "cloudflare_access_secret_arn" {
  value       = module.alloy.otlp_access_secret_arn
  description = "Secrets Manager ARN holding the CF-Access-Client-Id/Secret pair every product's task needs for OTEL_EXPORTER_OTLP_HEADERS."
}
