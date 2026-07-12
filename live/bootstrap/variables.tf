# Bootstrap is mostly zero-input (it creates the account-level singletons), but
# a few account-wide facts that products need to read live here so there's ONE
# source of truth exported via remote state (like kms_key_arn, oidc_provider_arn).

variable "cloudflare_zone_id" {
  type        = string
  default     = ""
  description = <<-EOT
    Cloudflare Zone ID for the qnsc.vn zone. One zone serves every product, so
    it's an account-level fact exported here (products read it from bootstrap
    remote state, the same way they read kms_key_arn). Find it on the Cloudflare
    dashboard → qnsc.vn → Overview → API section (right sidebar). Not sensitive
    (a zone ID is not a secret). Leave empty to skip DNS wiring org-wide.
  EOT
}
