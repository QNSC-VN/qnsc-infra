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
  name = "qnsc"
  slug = "qnsc"
  # "ap-southeast-0" was never a valid region_slug: the API silently accepted it
  # at create time and auto-assigned prod-ap-southeast-1 instead of erroring —
  # the WRONG region, confirmed by the access-policy API refusing to attach to
  # it ("Stack must be in region prod-ap-southeast-0"). This is the real,
  # correct region; matching it forces a genuine destroy+recreate of the
  # misplaced stack, safe here since it holds zero data.
  region_slug = "prod-ap-southeast-0"
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

# =============================================================================
# Alerting — Grafana Alerting ALONGSIDE CloudWatch Alarms, not replacing it.
# CloudWatch Alarms stay on infra-level signals (ECS task health, ALB target
# health); Grafana Alerting covers only what CloudWatch cannot see — the
# application-level telemetry this stack ingests (DB pool pressure, HTTP
# error rate, latency, in-process circuit breakers).
#
# A SECOND, DIFFERENT credential from otlp_push above: the resources below
# (contact point, notification policy, rule groups) live INSIDE the Grafana
# instance itself and are managed through the Grafana HTTP API, not the
# Grafana Cloud ORG API `cloud_access_policy_token` authenticates to. That
# token's scopes (`stacks:read stacks:write`) manage the STACK as an object;
# they cannot create an alert rule inside it. A stack-scoped SERVICE ACCOUNT
# is the credential for that surface — same split Grafana's own docs draw
# between "Cloud API" and "Grafana instance API".
resource "grafana_cloud_stack_service_account" "alerting" {
  stack_slug = grafana_cloud_stack.qnsc.slug
  name       = "terraform-alerting"
  role       = "Editor" # Alert rule CRUD needs Editor; Viewer cannot write, Admin is unneeded surface
}

resource "grafana_cloud_stack_service_account_token" "alerting" {
  stack_slug         = grafana_cloud_stack.qnsc.slug
  service_account_id = grafana_cloud_stack_service_account.alerting.id
  name               = "terraform-alerting-token"
  # No expiration set deliberately: this token is Terraform's own long-lived
  # management credential for the alerting surface, analogous to otlp_push's
  # token never rotating on a timer. Rotate by tainting this resource if it
  # ever needs to change, same as any other provider credential would.
}

provider "grafana" {
  alias = "stack"
  url   = grafana_cloud_stack.qnsc.url
  auth  = grafana_cloud_stack_service_account_token.alerting.key
}

# One folder for every product's alert rules — matches the single-stack,
# label-scoped-tenancy design everything else here follows. A per-product
# folder would just be a filter UI already gives you via the `product` label.
resource "grafana_folder" "alerts" {
  provider = grafana.stack
  title    = "Alerts"
}

# ONE contact point, ONE root notification policy — this org has one
# on-call surface today (M365/Teams), so per-product routing would be
# complexity with nothing to route TO. The `product` label every rule group
# carries (see observability-alerts module) is what makes per-product
# routing a one-line addition later — a `policy` block keyed on
# `matcher { label = "product" ... }` — without touching any product's own
# Terraform.
resource "grafana_contact_point" "teams" {
  provider = grafana.stack
  name     = "teams-alerts"

  teams {
    url = var.teams_webhook_url
  }
}

resource "grafana_notification_policy" "root" {
  provider       = grafana.stack
  contact_point  = grafana_contact_point.teams.name
  group_by       = ["alertname", "product"]
  group_wait     = "30s"
  group_interval = "5m"
  # Long repeat: a channel re-notified every default 4h for a still-firing
  # alert is exactly the kind of noise that trains people to ignore it.
  repeat_interval = "12h"
}

# Every product's alert rules need this UID to query Mimir — looked up once,
# here, rather than each product guessing Grafana Cloud's
# `grafanacloud-<slug>-prom` auto-provisioning convention independently.
data "grafana_data_source" "prometheus" {
  provider = grafana.stack
  name     = "grafanacloud-${grafana_cloud_stack.qnsc.slug}-prom"
}

variable "teams_webhook_url" {
  description = <<-EOT
    Microsoft Teams "Workflows" webhook URL (Teams' classic Incoming Webhook
    connectors were retired; this is a Logic Apps endpoint from a channel's
    Workflows app — "Post to a channel when a webhook request is received").
    Sensitive: treat like any other bearer credential embedded in a URL.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}
