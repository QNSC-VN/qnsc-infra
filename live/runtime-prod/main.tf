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
# One VPC + NAT + ALB (+ WAF, + shared cache in lean tier) shared by ALL
# products' prod stacks. Product prod stacks read these outputs via
# terraform_remote_state and create ONLY their own RDS + ECS + SQS + secrets
# + a host-based listener rule on this shared ALB.
#
# tier switch (see COST_POSTURE_PLAN Version A vs B):
#   lean → fck-nat, single-AZ egress, no flow logs, ONE shared cache node
#   ha   → NAT Gateway multi-AZ, flow logs; cache is per-product (NOT here)
#
# RDS and Fargate are always per-product and never live in this stack.
# =============================================================================

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  name   = "qnsc-runtime-prod"
  region = "ap-southeast-1"
  azs    = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  cloudflare_ipv4 = data.terraform_remote_state.bootstrap.outputs.cloudflare_ipv4
  is_ha           = var.tier == "ha"
}

# ── Shared VPC + NAT ──────────────────────────────────────────────────────────
module "network" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/network?ref=network-v1.1.2"

  name   = local.name
  region = local.region
  azs    = local.azs

  enable_interface_endpoints = true # prod: cut NAT egress cost for ECR/Secrets

  vpc_cidr             = "10.91.0.0/16"
  public_subnet_cidrs  = ["10.91.0.0/24", "10.91.1.0/24", "10.91.2.0/24"]
  private_subnet_cidrs = ["10.91.10.0/24", "10.91.11.0/24", "10.91.12.0/24"]
  data_subnet_cidrs    = ["10.91.20.0/24", "10.91.21.0/24", "10.91.22.0/24"]

  # lean = fck-nat single-AZ (cheap); ha = NAT Gateway multi-AZ (outbound HA).
  nat_type                = local.is_ha ? "gateway" : "instance"
  multi_az_nat            = local.is_ha
  app_port                = 3000
  enable_flow_logs        = local.is_ha
  flow_log_retention_days = 90 # SOC 2 CC7.2 minimum (only used when flow logs on)
  alb_ingress_cidrs       = local.cloudflare_ipv4

  tags = { Environment = "production" }
}

# ── ALB access logs (S3) ──────────────────────────────────────────────────────
module "alb_logs" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/alb-logs?ref=alb-logs-v1.0.0"

  bucket_name = "${local.name}-alb-logs"
  tags        = { Environment = "production" }
}

# ── Shared ALB (host-based routing across products) ───────────────────────────
# Deletion protection on + access logs. Products attach host-header listener
# rules (rally-api.qnsc.vn @100, opshub-api.qnsc.vn @200). certificate_arn must
# cover all product API hostnames — use a wildcard *.qnsc.vn ACM cert.
module "alb" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/alb?ref=alb-v1.0.0"

  name               = local.name
  security_group_ids = [module.network.sg_alb_id]
  subnet_ids         = module.network.public_subnet_ids
  certificate_arn    = var.acm_cert_arn

  enable_deletion_protection = true
  access_logs_bucket         = module.alb_logs.bucket_id

  tags = { Environment = "production" }
}

# ── WAF (regional, on the shared ALB) ─────────────────────────────────────────
# Version A (lean): Cloudflare edge owns the WAF (see live/edge + cf-edge), so
# this AWS WAFv2 is OFF by default (enable_aws_waf=false) to avoid double-WAF /
# double-pay. Flip on for the HA/compliance tier if you want origin-side defense
# in depth in addition to the edge. See COST_POSTURE_PLAN §10.
module "waf" {
  count  = var.enable_aws_waf ? 1 : 0
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/waf?ref=waf-v1.0.1"

  name                = local.name
  alb_arn             = module.alb.arn
  rate_limit_per_5min = var.rate_limit_per_5min

  tags = { Environment = "production" }
}

# ── Shared cache (LEAN tier only) ─────────────────────────────────────────────
# lean: ONE Valkey node shared by all products (key-prefixed: rally:*, opshub:*).
# ha:   cache is per-product (created in the product prod stack), so none here.
module "cache" {
  count  = local.is_ha ? 0 : 1
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/cache?ref=cache-v1.0.0"

  name              = local.name
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_cache_id

  mode      = "node" # node ~$12/mo vs serverless ~$90 floor
  node_type = "cache.t4g.micro"

  tags = { Environment = "production" }
}
