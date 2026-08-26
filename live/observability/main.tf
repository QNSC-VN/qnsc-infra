# =============================================================================
# Observability — shared Grafana Cloud stack + Alloy collector.
#
# One platform, every product, every environment — tenancy is a label
# (product, environment), never a separate stack. See the reference design:
# metrics/logs/traces/alerts through one OTel-native pipeline, open-core
# backend so outgrowing the SaaS tier is an infra move, never a rewrite.
#
# THE ONE MANUAL STEP THIS STACK CANNOT DO ITSELF: Grafana Cloud organizations
# are not provisioned via API. Sign up at grafana.com (free, no card), create
# a Cloud Access Policy with scopes `stacks:read stacks:write`, and put its
# token in this repo's GRAFANA_CLOUD_API_KEY secret. Everything past that —
# the stack itself, its Mimir/Loki/Tempo push credentials, the collector that
# uses them — this file provisions.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    grafana    = { source = "grafana/grafana", version = "~> 3.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/observability/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

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

provider "grafana" {
  cloud_access_policy_token = var.grafana_cloud_api_key
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

variable "grafana_cloud_api_key" {
  description = "Cloud Access Policy token (stacks:read, stacks:write) — the one credential created by hand. See header comment."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_account_id" {
  type = string
}

# ── Upstream shared state ─────────────────────────────────────────────────────
data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

data "terraform_remote_state" "runtime_dev" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/runtime-dev/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

data "terraform_remote_state" "runtime_prod" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/runtime-prod/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# ── Grafana Cloud stack ────────────────────────────────────────────────────────
# One stack, all four products' dev+prod telemetry. Free tier at this org's
# volume (10k series / 50GB logs+traces+profiles / 14-day retention) — see the
# growth path in the design doc for what changes, and what doesn't, past it.
resource "grafana_cloud_stack" "qnsc" {
  name        = "qnsc"
  slug        = "qnsc"
  region_slug = "ap-southeast-0" # nearest Grafana Cloud region to ap-southeast-1
}

# Scoped write-only: this policy can push metrics/logs/traces, nothing else —
# it is what the collector authenticates with, so it carries no read/admin
# surface a leaked task-role credential could use beyond ingest.
resource "grafana_cloud_access_policy" "alloy_push" {
  region       = "ap-southeast-0"
  name         = "alloy-collector-push"
  display_name = "Alloy collector — write-only"

  scopes = ["metrics:write", "logs:write", "traces:write"]

  realm {
    type       = "stack"
    identifier = grafana_cloud_stack.qnsc.id
  }
}

resource "grafana_cloud_access_policy_token" "alloy_push" {
  region           = "ap-southeast-0"
  access_policy_id = grafana_cloud_access_policy.alloy_push.policy_id
  name             = "alloy-collector-push-token"
}

# ── Compute for the collector ─────────────────────────────────────────────────
# Its own cluster, not a product's. An ECS cluster is a free namespace — this
# keeps the collector's blast radius (and its IAM) separate from any product,
# the same reasoning every product already gets its own dedicated cluster.
resource "aws_ecs_cluster" "observability" {
  name = "observability"
  tags = { Layer = "platform" }
}

module "alloy" {
  source = "../../modules/alloy-collector"

  vpc_id             = data.terraform_remote_state.runtime_dev.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.runtime_dev.outputs.all_private_subnet_ids
  cluster_arn        = aws_ecs_cluster.observability.arn
  kms_key_arn        = data.terraform_remote_state.bootstrap.outputs.kms_key_arn

  cloudflare_account_id = var.cloudflare_account_id
  cloudflare_zone_id    = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  tunnel_hostname       = "otel.qnsc.vn"

  prometheus_remote_write_url = grafana_cloud_stack.qnsc.prometheus_remote_write_endpoint
  prometheus_username         = grafana_cloud_stack.qnsc.prometheus_user_id
  loki_url                    = grafana_cloud_stack.qnsc.logs_url
  loki_username               = grafana_cloud_stack.qnsc.logs_user_id
  tempo_url                   = grafana_cloud_stack.qnsc.traces_url
  tempo_username              = grafana_cloud_stack.qnsc.traces_user_id
  grafana_cloud_push_token    = grafana_cloud_access_policy_token.alloy_push.token

  # Both shared ALBs — dev's and prod's — folded into the same Mimir. Filtered
  # for null rather than passed raw: runtime-prod's apply is gated behind a
  # manual workflow_dispatch (see infra-apply.yml), so on this stack's very
  # first deploy its ALB may not exist in state yet, and `alb_arn` is `null`
  # by design until it does (see runtime-prod's own output comment).
  alb_arns = {
    for k, v in {
      develop    = data.terraform_remote_state.runtime_dev.outputs.alb_arn
      production = data.terraform_remote_state.runtime_prod.outputs.alb_arn
    } : k => v if v != null
  }

  tags = { Layer = "platform" }
}
