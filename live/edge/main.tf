terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/edge/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

# Cloudflare provider — reads the token from TF_VAR_cloudflare_api_token (or the
# CLOUDFLARE_API_TOKEN env var). Needs Zone:WAF + Zone:Rulesets edit scope on
# qnsc.vn. Leave empty to skip provider auth (e.g. plan-only bootstrapping).
provider "cloudflare" {
  api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : null
}

# =============================================================================
# Shared edge governance — Cloudflare WAF + rate-limiting for the qnsc.vn zone.
#
# Zone-level (one zone fronts every product), so it lives in the platform layer
# alongside runtime-*, not in any single product stack. The zone_id is read
# from qnsc-infra bootstrap (single source of truth). Managed WAF is OFF by
# default (Pro+ only); rate limiting is on with a conservative per-IP default.
#
# WAF ownership: if enable_managed_waf is turned on for prod, remove the AWS
# `waf` module from runtime-prod — never run both.
# =============================================================================

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

module "edge" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/cf-edge?ref=cf-edge-v1.0.0"

  zone_id = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id

  # Conservative per-IP rate limit on the product API surface. Free tier allows
  # this single rule; raise/split once on Pro+.
  rate_limit_rules = [{
    ref                 = "api_default"
    description         = "Rate-limit product API endpoints per client IP"
    expression          = "(http.request.uri.path matches \"^/v1/\")"
    period              = 60
    requests_per_period = 300
    mitigation_timeout  = 60
  }]

  # Managed + OWASP rulesets — requires Pro+. Keep false until the zone plan is
  # confirmed; when enabling for prod, drop the AWS waf module from runtime-prod.
  enable_managed_waf = var.enable_managed_waf

  custom_firewall_rules = var.custom_firewall_rules
}
