output "tunnel_hostname" {
  value       = var.tunnel_hostname
  description = "Public OTLP ingest endpoint every product points OTEL_EXPORTER_OTLP_ENDPOINT at."
}

output "service_name" {
  value = aws_ecs_service.alloy.name
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.alloy.name
}

output "otlp_access_secret_arn" {
  value       = aws_secretsmanager_secret.otlp_access_token.arn
  description = "Secrets Manager ARN holding the Cloudflare Access service-token pair (client_id/client_secret) products need to reach the OTLP endpoint."
}
