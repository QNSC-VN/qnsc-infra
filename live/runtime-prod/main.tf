terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/runtime-prod/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Org         = "qnsc"
      ManagedBy   = "opentofu"
      Layer       = "platform"
      Environment = "production"
    }
  }
}

# =============================================================================
# Shared runtime layer — PRODUCTION  (STAGED — do not apply until launch)
#
# One VPC + NAT + ALB (+ WAF) shared by ALL products' prod stacks. Product prod
# stacks read these outputs via terraform_remote_state and create ONLY their own
# RDS + cache + ECS + SQS + secrets + a host-based listener rule on this shared
# ALB.
#
# Runtime posture: fck-nat single-AZ egress. RDS, cache, and Fargate are always
# per-product and never live in this stack.
# =============================================================================

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# Wildcard *.qnsc.vn ACM cert is created + validated by the edge stack. Read its
# ARN here instead of taking it as an input variable — single source of truth,
# no GitHub var to set/sync per environment. Applies after apply-edge (see CI).
data "terraform_remote_state" "edge" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/edge/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  name   = "qnsc-runtime-prod"
  region = "ap-southeast-1"
  azs    = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  cloudflare_ipv4 = data.terraform_remote_state.bootstrap.outputs.cloudflare_ipv4
}

# ── Shared VPC + NAT ──────────────────────────────────────────────────────────
module "network" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/network?ref=network-v1.1.2"

  name   = local.name
  region = local.region
  azs    = local.azs

  # OFF, deliberately. The module places one Interface endpoint ENI per private
  # subnet, so three endpoints across three AZs bill 9 ENI-hours at $0.013 =
  # ~$85/mo. Those endpoints processed 1.246 GB in July.
  #
  # WHEN TO TURN THIS BACK ON — the trigger is INTERNET EGRESS, not NAT processing.
  # An fck-nat instance has no per-GB fee, so the cost of routing this traffic over
  # NAT is the data-transfer-out charge on the far side. Measured 2026-07-28:
  # `APS1-DataTransfer-Out-Bytes` was 12.94 GB for the month and **99% of it was ECR**
  # (12.78 GB) — image pulls, which scale with deploy frequency, not with users. It
  # billed $0 only because of the 100 GB/month AWS free allowance, i.e. ~15% consumed
  # pre-launch.
  #
  # So: at roughly 70 GB/month of internet egress, re-enable — but pin `subnet_ids` to
  # ONE subnet (~$28/mo, not $85), because the ECR pull path does not need per-AZ
  # endpoints to be correct, only to be present. Past 100 GB/month the alternative is
  # ~$0.12/GB in ap-southeast-1, which overtakes a single-subnet endpoint at ~230 GB.
  #
  # Check with:
  #   aws ce get-cost-and-usage --time-period Start=<month-start>,End=<today> \
  #     --granularity MONTHLY --metrics UsageQuantity \
  #     --filter '{"Dimensions":{"Key":"USAGE_TYPE","Values":["APS1-DataTransfer-Out-Bytes"]}}' \
  #     --group-by Type=DIMENSION,Key=SERVICE --region us-east-1
  #
  # The free S3 gateway endpoint below already carries the ECR layer blobs, which is
  # why this number is not far worse.
  enable_interface_endpoints = false

  vpc_cidr             = "10.91.0.0/16"
  public_subnet_cidrs  = ["10.91.0.0/24", "10.91.1.0/24", "10.91.2.0/24"]
  private_subnet_cidrs = ["10.91.10.0/24", "10.91.11.0/24", "10.91.12.0/24"]
  data_subnet_cidrs    = ["10.91.20.0/24", "10.91.21.0/24", "10.91.22.0/24"]

  # fck-nat single-AZ egress — one cost-efficient shared NAT for all prod products.
  nat_type                = "instance"
  multi_az_nat            = false
  app_port                = 3000
  enable_flow_logs        = false
  flow_log_retention_days = 90 # SOC 2 CC7.2 minimum (only used when flow logs on)
  alb_ingress_cidrs       = local.cloudflare_ipv4

  tags = { Environment = "production" }
}

# ── ALB access logs (S3) ──────────────────────────────────────────────────────
module "alb_logs" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/alb-logs?ref=alb-logs-v1.0.1"

  bucket_name = "${local.name}-alb-logs"
  tags        = { Environment = "production" }
}

# ── Shared ALB (host-based routing across products) ───────────────────────────
# Deletion protection on + access logs. Products attach host-header listener
# rules (rally-api.qnsc.vn @100, opshub-api.qnsc.vn @200). certificate_arn is the
# wildcard *.qnsc.vn cert from the edge stack (read via terraform_remote_state) —
# it covers every product API hostname on this ALB.
module "alb" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/alb?ref=alb-v1.0.1"

  name               = local.name
  security_group_ids = [module.network.sg_alb_id]
  certificate_arn    = data.terraform_remote_state.edge.outputs.acm_cert_arn

  # All three AZs, unlike runtime-dev's two. Each enabled AZ claims a public IPv4
  # at $3.65/mo, and that third address is the cheapest ingress redundancy on the
  # account: it keeps the load balancer serving when two AZs are impaired, which is
  # the one failure mode Cloudflare in front of it cannot cover.
  subnet_ids = module.network.public_subnet_ids

  enable_deletion_protection = true
  access_logs_bucket         = module.alb_logs.bucket_id

  tags = { Environment = "production" }
}

# ── WAF (regional, on the shared ALB) ─────────────────────────────────────────
# Cloudflare edge owns the WAF (see live/edge + cf-edge), so this AWS WAFv2 is
# OFF by default (enable_aws_waf=false) to avoid double-WAF / double-pay. Flip on
# only if you want origin-side defense in depth in addition to the edge. See
# COST_POSTURE_PLAN §10.
module "waf" {
  count  = var.enable_aws_waf ? 1 : 0
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/waf?ref=waf-v1.1.1"

  name                = local.name
  alb_arn             = module.alb.arn
  rate_limit_per_5min = var.rate_limit_per_5min

  tags = { Environment = "production" }
}

# ── Cache ─────────────────────────────────────────────────────────────────────
# No shared cache here — each product's prod stack owns its own dedicated Valkey
# node (reusing sg_cache_id + data subnets from this stack), so one product can't
# evict another's sessions. See rally/opshub infra/live/prod (module.cache).
