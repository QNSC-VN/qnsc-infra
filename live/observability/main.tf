# =============================================================================
# Observability — the Grafana Cloud stack every product pushes telemetry to.
#
# This is the ONLY thing missing. Every product already carries the rest:
# `qnsc-tf-modules/modules/observability-agent` is a per-task OTel Collector
# SIDECAR, already wired into rally's api and worker tasks, currently a no-op
# because `otlp_endpoint` is unset — no shared collector, no ingress, no
# tunnel. A sidecar pushes OUTBOUND over the NAT egress every task already
# has; nothing needs to reach IN. See the module's own README for why tail
# sampling is deliberately not attempted there (needs a trace-id-aware
# gateway that does not exist yet — a real future gap, not this one).
#
# `qnsc-tf-modules/modules/observability` (CloudWatch alarms/dashboard) is a
# separate, already-wired, already-working thing. Nothing here touches it.
#
# THE ONE MANUAL STEP THIS STACK CANNOT DO ITSELF: Grafana Cloud organizations
# are not provisioned via API. Sign up at grafana.com (free, no card), create
# a Cloud Access Policy with scopes `stacks:read stacks:write`, and put its
# token in this repo's GRAFANA_CLOUD_API_KEY secret. Everything past that —
# the stack itself, and the push token every product's sidecar authenticates
# with — this file provisions.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    grafana = { source = "grafana/grafana", version = "~> 3.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/observability/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "grafana" {
  cloud_access_policy_token = var.grafana_cloud_api_key
}

variable "grafana_cloud_api_key" {
  description = "Cloud Access Policy token (stacks:read, stacks:write) — the one credential created by hand. See header comment."
  type        = string
  sensitive   = true
}

# One stack, all four products' dev+prod telemetry — tenancy is the
# product/environment resource attributes each sidecar sets, never a
# separate stack. Free tier at this org's volume (10k series / 50GB
# logs+traces+profiles / 14-day retention) — see the growth path in the
# reference design doc for what changes, and what doesn't, past it.
resource "grafana_cloud_stack" "qnsc" {
  name        = "qnsc"
  slug        = "qnsc"
  region_slug = "ap-southeast-0" # nearest Grafana Cloud region to ap-southeast-1
}

# Scoped write-only: this is what every product's sidecar authenticates
# with, so it carries no read/admin surface a leaked task credential could
# use beyond ingest.
resource "grafana_cloud_access_policy" "otlp_push" {
  region       = "prod-ap-southeast-0" # access-policy API uses a different region-slug format than the stack's
  name         = "otlp-sidecar-push"
  display_name = "OTel sidecar push — write-only"

  scopes = ["metrics:write", "logs:write", "traces:write"]

  realm {
    type       = "stack"
    identifier = grafana_cloud_stack.qnsc.id
  }
}

resource "grafana_cloud_access_policy_token" "otlp_push" {
  region           = "prod-ap-southeast-0"
  access_policy_id = grafana_cloud_access_policy.otlp_push.policy_id
  name             = "otlp-sidecar-push-token"
}
