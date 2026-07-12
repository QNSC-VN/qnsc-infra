terraform {
  required_version = ">= 1.9"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
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

# AWS provider — ACM lives in the ALB's own region (ap-southeast-1). Regional
# ALB certs (unlike CloudFront's us-east-1 requirement) must sit in-region.
provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Org       = "qnsc"
      ManagedBy = "opentofu"
      Layer     = "platform"
    }
  }
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

  # Conservative per-IP rate limit on the product API surface. The free plan's
  # single included rate-limiting rule only permits a 10s counting period, a 10s
  # mitigation timeout, and simple expression operators (no `matches` regex —
  # that needs Advanced Rate Limiting). Raise/split once on Pro+.
  rate_limit_rules = [{
    ref                 = "api_default"
    description         = "Rate-limit product API endpoints per client IP"
    expression          = "(starts_with(http.request.uri.path, \"/v1/\"))"
    period              = 10
    requests_per_period = 300
    mitigation_timeout  = 10
  }]

  # Managed + OWASP rulesets — requires Pro+. Keep false until the zone plan is
  # confirmed; when enabling for prod, drop the AWS waf module from runtime-prod.
  enable_managed_waf = var.enable_managed_waf

  custom_firewall_rules = var.custom_firewall_rules
}

# =============================================================================
# Shared wildcard TLS certificate — *.qnsc.vn in ap-southeast-1.
#
# One regional ACM cert fronts every product API on the shared ALB
# (rally-api-dev.qnsc.vn, opshub-api-dev.qnsc.vn, …), so it lives here in the
# platform edge layer, not in any product or runtime stack. Its ARN is exported
# and consumed by runtime-dev/runtime-prod via terraform_remote_state — no human
# ever copies a cert ARN into a GitHub variable.
#
# Scope is deliberately *.qnsc.vn only (no apex SAN): the ALB serves API
# subdomains, while the apex + web hosts live on Cloudflare Pages with their own
# edge TLS. A single-label wildcard covers every *-api-<env>.qnsc.vn host.
#
# Validation is DNS-01 through the same Cloudflare zone this stack already owns
# (token: Zone:DNS:Edit). for_each is keyed on domain_name (known at plan time —
# resource_record_name is computed and would break for_each).
# =============================================================================
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.certificate_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "qnsc-wildcard-${var.certificate_domain}" }
}

resource "cloudflare_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options :
    dvo.domain_name => {
      name    = dvo.resource_record_name
      type    = dvo.resource_record_type
      content = dvo.resource_record_value
    }
  }

  zone_id         = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  name            = trimsuffix(each.value.name, ".")
  type            = each.value.type
  content         = trimsuffix(each.value.content, ".")
  ttl             = 60
  proxied         = false # validation CNAME — DNS-only, never orange-clouded
  comment         = "ACM DNS validation for *.${var.certificate_domain} (qnsc-infra/edge)"
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in cloudflare_record.acm_validation : r.hostname]
}

# =============================================================================
# Cloudflare Pages — static sites (qnsc-landing, …).
#
# The Pages *project* is infrastructure, so it is declared here in code rather
# than clicked into existence. This makes it reproducible across account
# migrations (a fresh Cloudflare account is one `tofu apply` away) and removes
# any manual dashboard step — the exact failure that broke the qnsc-landing
# deploy after the account move. The web-deploy CI only uploads built assets to
# the already-provisioned project via `wrangler pages deploy` — pure CD, no
# provisioning.
#
# Direct-upload project (no `source` block → not Git-connected). The production
# branch is `main` to match the deploy command's `--branch=main`.
# =============================================================================
resource "cloudflare_pages_project" "landing" {
  account_id        = var.cloudflare_account_id
  name              = "qnsc-landing"
  production_branch = "main"
}
