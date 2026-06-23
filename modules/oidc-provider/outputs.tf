output "arn" {
  value       = aws_iam_openid_connect_provider.github.arn
  description = "GitHub OIDC provider ARN — pass to product infra iam-oidc modules."
}

output "url" {
  value       = aws_iam_openid_connect_provider.github.url
  description = "GitHub OIDC provider URL."
}
