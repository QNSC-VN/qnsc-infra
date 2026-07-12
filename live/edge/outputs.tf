output "ratelimit_ruleset_id" {
  value       = module.edge.ratelimit_ruleset_id
  description = "ID of the rate-limiting ruleset."
}

output "managed_ruleset_id" {
  value       = module.edge.managed_ruleset_id
  description = "ID of the managed-WAF ruleset (null when disabled)."
}

output "custom_ruleset_id" {
  value       = module.edge.custom_ruleset_id
  description = "ID of the custom-firewall ruleset (null when none)."
}

output "acm_cert_arn" {
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
  description = "Validated wildcard *.qnsc.vn ACM cert ARN (ap-southeast-1) for the shared ALB. Consumed by runtime-dev/runtime-prod via terraform_remote_state."
}
