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
# a Cloud Access Policy with scopes `stacks:read stacks:write
# stack-service-accounts:write`, and put its
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
  description = "Cloud Access Policy token (stacks:read, stacks:write, stack-service-accounts:write) — the one credential created by hand. See header comment."
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
# Grafana Cloud ORG API `cloud_access_policy_token` authenticates to. Even
# with `stack-service-accounts:write` added (real 403 hit on first apply —
# `stacks:read stacks:write` alone does not cover creating a stack service
# account, and that scope is what fixed it), the ORG token still cannot
# create an ALERT RULE inside the stack; it can only create the service
# account below, which is what CAN. A stack-scoped SERVICE ACCOUNT is the
# credential for that surface — same split Grafana's own docs draw between
# "Cloud API" and "Grafana instance API".
#
# `role = "Admin"`, NOT "Editor" — reversed from an earlier attempt, by two
# real, distinct 403s, not by preference. Editor's basic role decomposes
# into fixed roles that do not include reading an arbitrary folder by UID
# (only the special General folder), so the very first Terraform read-back
# after creating a folder failed. Granting the missing `fixed:folders:writer`
# role explicitly seemed like the least-privilege fix — but ASSIGNING a
# role is ITSELF gated behind `users.roles:add/remove` /
# `teams.roles:add/remove`, which Editor also lacks, and a service account
# cannot grant itself permissions it does not already have. That's a genuine
# dead end, not a missing scope to add: an Editor-scoped automation
# principal cannot self-provision the folder RBAC an Editor-scoped
# automation principal needs. Admin is the correct role for a Terraform
# principal managing folders + alert rules + notification policy end to
# end, not an unneeded broadening.
resource "grafana_cloud_stack_service_account" "alerting" {
  stack_slug = grafana_cloud_stack.qnsc.slug
  name       = "terraform-alerting"
  role       = "Admin"
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

# PARENT folder — each product gets its own SUBFOLDER underneath (see
# dashboards_folder_uid's own description for why this one is nested and
# alerts is not).
resource "grafana_folder" "dashboards" {
  provider = grafana.stack
  title    = "Dashboards"
}

# Rally's own subfolder — created HERE, ONCE, not inside rally's own stack
# module. A real bug this shipped as: rally's develop and prod environments
# are separate Terraform ROOT MODULES with separate state files, so each
# one's `grafana_folder.product_dashboards` independently created its OWN
# "Rally" folder the moment prod applied for the first time — two real,
# separate folders with the same title, sitting as siblings, each holding
# only that one environment's dashboards. Centralizing it here is the same
# fix as `alerts_folder_uid`/`dashboards_folder_uid` already being resolved
# once and passed DOWN as a plain UID input, not re-derived per environment.
resource "grafana_folder" "rally_dashboards" {
  provider          = grafana.stack
  parent_folder_uid = grafana_folder.dashboards.uid
  title             = "Rally"
}

# Resolved directly, not via a dashboard template variable: a Grafana
# dashboard template var of type "datasource" needs a populated `current`
# value to render correctly on a PROVISIONED (Terraform-loaded) dashboard,
# and that shape is exactly the kind of undocumented, easy-to-get-wrong
# JSON this session already got burned by twice (alert rule models,
# Fluent Bit config) — not worth the risk for zero benefit when there is
# only one datasource. Safe to look up directly here, unlike the earlier
# attempt in this same file: THAT one broke because the service account
# token the read would authenticate with was being created in the SAME
# plan (a data source can't defer to apply the way a resource can). The
# token now already exists in state from prior applies, so this read is
# no longer racing its own credential's creation.
data "grafana_data_source" "prometheus" {
  provider = grafana.stack
  name     = "grafanacloud-${grafana_cloud_stack.qnsc.slug}-prom"
}

# ONE system-level dashboard, split by `service_namespace` (the product
# label observability-agent already stamps on every signal) rather than
# hardcoding a panel per product. Works today with only rally emitting
# data — one line per graph — and needs no edit when opshub/qnsc-kb-backend
# start pushing telemetry through the same stack: they show up as a second
# legend series automatically. A per-product dashboard (rally's own, more
# detailed) is a separate thing, owned by that product's own repo — see
# rally/infra's dashboard for why this split, not one giant dashboard here.
resource "grafana_dashboard" "system_overview" {
  provider  = grafana.stack
  folder    = grafana_folder.dashboards.uid
  overwrite = true

  config_json = jsonencode({
    title         = "System Overview"
    uid           = "system-overview"
    timezone      = "browser"
    editable      = false
    schemaVersion = 39
    time          = { from = "now-6h", to = "now" }
    refresh       = "1m"
    tags          = ["system", "provisioned"]

    panels = [
      # By (service_namespace, deployment_environment_name), not
      # service_namespace alone — a real gap caught before prod ever sent
      # data: with only develop emitting, these three panels HAPPENED to
      # look env-scoped, but the underlying query wasn't. The moment prod
      # activates, its numbers would have blended into the SAME line as
      # develop's (summed for rate/count, averaged into one ratio for
      # error rate) instead of showing as a second, separate series —
      # exactly the kind of silent merge a "which environment is actually
      # unhealthy" dashboard exists to prevent.
      {
        id         = 1
        title      = "HTTP request rate, by product + env"
        type       = "timeseries"
        gridPos    = { h = 8, w = 12, x = 0, y = 0 }
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        targets = [{
          expr         = "sum(rate(http_server_requests_total[5m])) by (service_namespace, deployment_environment_name)"
          legendFormat = "{{service_namespace}} ({{deployment_environment_name}})"
          refId        = "A"
        }]
      },
      {
        id          = 2
        title       = "HTTP error rate, by product + env"
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 12, y = 0 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "percentunit" } }
        targets = [{
          expr         = "sum(rate(http_server_errors_total[5m])) by (service_namespace, deployment_environment_name) / sum(rate(http_server_requests_total[5m])) by (service_namespace, deployment_environment_name)"
          legendFormat = "{{service_namespace}} ({{deployment_environment_name}})"
          refId        = "A"
        }]
      },
      {
        id          = 3
        title       = "HTTP p99 latency, by product + env"
        type        = "timeseries"
        gridPos     = { h = 8, w = 12, x = 0, y = 8 }
        datasource  = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        fieldConfig = { defaults = { unit = "ms" } }
        targets = [{
          expr         = "histogram_quantile(0.99, sum(rate(http_server_duration_milliseconds_bucket[5m])) by (le, service_namespace, deployment_environment_name))"
          legendFormat = "{{service_namespace}} ({{deployment_environment_name}})"
          refId        = "A"
        }]
      },
      {
        id         = 4
        title      = "Active Mimir series (this stack, all products)"
        type       = "stat"
        gridPos    = { h = 8, w = 12, x = 12, y = 8 }
        datasource = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        # Free tier ceiling is 10k series — this is the one number that
        # says "about to lose data silently" before it happens.
        targets = [{
          expr  = "count({__name__=~\".+\"})"
          refId = "A"
        }]
      },
    ]
  })
}

# ONE contact point, ONE root notification policy — this org has one
# on-call surface today (M365/Teams), so per-product routing would be
# complexity with nothing to route TO. The `product` label every rule group
# carries (see observability-alerts module) is what makes per-product
# routing a one-line addition later — a `policy` block keyed on
# `matcher { label = "product" ... }` — without touching any product's own
# Terraform.
#
# Gated on teams_webhook_url being set, unlike everything else in this
# "Alerting" section: Grafana's API genuinely REJECTS an empty `teams { url }`
# — this isn't the harmless-default pattern otlp_endpoint uses (an unset
# string there just means "no consumer configured yet"), it's a real
# validation failure at apply time. `count`, not `for_each` — there is
# exactly one of each, and count on a bool is simpler for a single
# on/off resource than a for_each over a conditional set.
locals {
  alerting_enabled = var.teams_webhook_url != ""
}

resource "grafana_contact_point" "teams" {
  count    = local.alerting_enabled ? 1 : 0
  provider = grafana.stack
  name     = "teams-alerts"

  teams {
    url = var.teams_webhook_url
  }
}

resource "grafana_notification_policy" "root" {
  count         = local.alerting_enabled ? 1 : 0
  provider      = grafana.stack
  contact_point = grafana_contact_point.teams[0].name
  # "env" is REQUIRED here, not "product" alone — caught in a pre-prod
  # audit, before it could bite: with only develop's alert rules active
  # this was invisible, but the moment prod's rules activate, a develop
  # "http-5xx-rate" firing and a prod "http-5xx-rate" firing would GROUP
  # INTO ONE Teams notification (same alertname, same product), reading
  # as one incident when it's two, in two different environments with two
  # completely different urgencies.
  group_by       = ["alertname", "product", "env"]
  group_wait     = "30s"
  group_interval = "5m"
  # Long repeat: a channel re-notified every default 4h for a still-firing
  # alert is exactly the kind of noise that trains people to ignore it.
  repeat_interval = "12h"
}

# Stack-wide, not per-product — lives here because the "Active Mimir series"
# panel it alerts on the same number as does too (System Overview dashboard,
# above). This is the free-tier-cap alert Grafana Cloud's own Cost
# Management/Usage Alerts feature would otherwise cover, EXCEPT that feature
# has no Terraform resource (checked the provider source directly — no
# usage/cost/billing resource exists), so it can only be built as code by
# reusing the same alerting pipeline every other rule in this stack already
# uses. 8000 = 80% of the 10k free-tier ceiling, a warning buffer before
# ingestion starts silently dropping series.
#
# NOT covering log/trace GB the same way: there is no Prometheus metric this
# stack's own Mimir exposes for "GB ingested this month" the way it exposes
# series count via `{__name__=~".+"}` — that number lives only in Grafana
# Cloud's billing backend. Set that one threshold by hand in Cost Management
# and Billing -> Usage Alerts (Logs, ~40 GiB) until Grafana ships a
# Terraform-manageable equivalent.
resource "grafana_rule_group" "series_near_cap" {
  count            = local.alerting_enabled ? 1 : 0
  provider         = grafana.stack
  name             = "platform (stack-wide)"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  rule {
    name           = "mimir-series-near-free-tier-cap"
    condition      = "B"
    for            = "15m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      query_type     = "instant"
      datasource_uid = data.grafana_data_source.prometheus.uid

      relative_time_range {
        from = 900
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        datasource    = { type = "prometheus", uid = data.grafana_data_source.prometheus.uid }
        expr          = "count({__name__=~\".+\"})"
        instant       = true
        range         = false
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    data {
      ref_id         = "B"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId      = "B"
        type       = "threshold"
        datasource = { type = "__expr__", uid = "__expr__" }
        expression = "A"
        conditions = [
          {
            evaluator = {
              type   = "gt"
              params = [8000]
            }
          }
        ]
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    labels = {
      product  = "platform"
      severity = "warning"
    }

    annotations = {
      summary = "Active Mimir series across the whole stack (all products) is above 8000 — 80% of the 10k free-tier ceiling. New series will start being silently dropped past 10k."
    }
  }
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
