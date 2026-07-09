variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = <<-EOT
    Cloudflare API token with Zone:WAF + Zone:Rulesets edit scope on qnsc.vn.
    Supplied via TF_VAR_cloudflare_api_token in CI. Leave empty to skip provider
    auth. The zone ID is NOT an input — it is read from qnsc-infra bootstrap
    remote state (one source of truth).
  EOT
}

variable "enable_managed_waf" {
  type        = bool
  default     = false
  description = "Deploy Cloudflare Managed + OWASP rulesets (Pro+ plan only). When enabling for prod, drop the AWS waf module from runtime-prod."
}

variable "custom_firewall_rules" {
  type = list(object({
    ref         = string
    description = string
    expression  = string
    action      = string
  }))
  default     = []
  description = "Optional custom expression firewall rules passed through to the cf-edge module."
}
