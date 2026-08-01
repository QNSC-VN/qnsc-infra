terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/runtime-dev/terraform.tfstate"
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
      Environment = "develop"
    }
  }
}

# =============================================================================
# Shared runtime layer — DEVELOP
#
# One VPC + fck-nat + ALB shared by ALL products' develop stacks (rally,
# opshub, …). Product env stacks read this stack's outputs via
# terraform_remote_state and create ONLY their own RDS + ECS + SQS + secrets
# + a host-based listener rule on this shared ALB (rally=100, opshub=200, …).
#
# Dev has NO shared cache here: each product's develop stack provisions its own
# cache (rally: a single-node ElastiCache; opshub: currently a per-task Valkey
# sidecar), so this stack is network + ingress only. RDS and Fargate are always
# per-product and never live here.
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
  name   = "qnsc-runtime-dev"
  region = "ap-southeast-1"
  azs    = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  # Single source of truth for Cloudflare edge IPs (bootstrap). The API
  # subdomains are Cloudflare-proxied, so the ALB only ever sees CF edge IPs.
  cloudflare_ipv4 = data.terraform_remote_state.bootstrap.outputs.cloudflare_ipv4

  # ── Serving AZs (cost) ──────────────────────────────────────────────────────
  # The VPC still has subnets in all three AZs — `local.azs` above is unchanged, so the
  # address space, route tables and NAT are untouched and widening later needs no CIDR
  # work. This is only about which AZs actually SERVE: the ALB enables one public subnet
  # per entry (one public IPv4 each, $3.65/mo) and product ECS services are placed in the
  # matching private subnets.
  #
  # ONE list drives both, deliberately. The ALB reading a different set from the services
  # is precisely the bug that rolled back opshub#85 (see module.alb below), and the only
  # durable fix is to make the mismatch unrepresentable rather than to remember the rule.
  #
  # TWO, not one. An Application Load Balancer cannot be single-AZ — AWS rejects the
  # apply outright:
  #
  #   ValidationError: At least two subnets in two different Availability Zones
  #   must be specified
  #
  # So two is the floor for any ALB, and the saving here is one address ($3.65/mo), not
  # two. Verified against the live API on 2026-08-02, not inferred from docs.
  #
  # Develop serves from two AZs. Production serves from three — see runtime-prod/main.tf,
  # which has no equivalent of this local.
  serving_azs = ["ap-southeast-1a", "ap-southeast-1b"]

  az_index = { for i, az in local.azs : az => i }

  alb_public_subnet_ids = [
    for az in local.serving_azs : module.network.public_subnet_ids[local.az_index[az]]
  ]

  serving_private_subnet_ids = [
    for az in local.serving_azs : module.network.private_subnet_ids[local.az_index[az]]
  ]
}

# ── Shared VPC + fck-nat (egress only) ────────────────────────────────────────
module "network" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/network?ref=network-v1.1.2"

  name   = local.name
  region = local.region
  azs    = local.azs

  enable_interface_endpoints = false # dev: NAT covers egress — save ~$22/mo

  vpc_cidr             = "10.90.0.0/16"
  public_subnet_cidrs  = ["10.90.0.0/24", "10.90.1.0/24", "10.90.2.0/24"]
  private_subnet_cidrs = ["10.90.10.0/24", "10.90.11.0/24", "10.90.12.0/24"]
  data_subnet_cidrs    = ["10.90.20.0/24", "10.90.21.0/24", "10.90.22.0/24"]

  nat_type          = "instance" # fck-nat t4g.nano ~$3/mo vs NAT GW ~$33/mo
  app_port          = 3000
  enable_flow_logs  = false
  alb_ingress_cidrs = local.cloudflare_ipv4 # lock ALB to Cloudflare orange-cloud IPs

  tags = { Environment = "develop" }
}

# ── Shared ALB (host-based routing across products) ───────────────────────────
# Product api services attach a host-header listener rule (e.g.
# rally-api-dev.qnsc.vn @ priority 100, opshub-api-dev.qnsc.vn @ 200).
# certificate_arn is the wildcard *.qnsc.vn cert from the edge stack (read via
# terraform_remote_state) — it covers every product API hostname on this ALB.
module "alb" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/alb?ref=alb-v1.0.1"

  name               = local.name
  security_group_ids = [module.network.sg_alb_id]
  certificate_arn    = data.terraform_remote_state.edge.outputs.acm_cert_arn

  # SINGLE AZ in develop (decided 2026-08-02), against runtime-prod's three.
  #
  # An ALB bills one public IPv4 per ENABLED AZ ($3.65/mo each), so three AZs here cost
  # $10.95/mo to give a non-production environment an availability property nobody is
  # paged for. Develop's failure mode when its one AZ is impaired is "wait, or change
  # `local.serving_azs` and apply" — acceptable for an environment exercised by CI and a
  # handful of engineers.
  #
  # THIS IS ONLY SAFE BECAUSE THE SERVICES MOVE WITH IT. The history here matters: this
  # was `slice(..., 0, 2)` once before, and it broke deploys. Cross-zone load balancing
  # spreads traffic across targets in the ALB's ENABLED AZs; a target in an AZ the ALB
  # has no subnet in is unreachable, and AWS says so in as many words —
  #
  #   (port 3000) is unhealthy in (target-group .../opshub-develop-api/...) due to
  #   (reason Target is in an Availability Zone that is not enabled for the load balancer)
  #
  # — so roughly one task placement in three landed in an AZ that could never pass a
  # health check, and the deployment circuit breaker rolled it back. It presented as
  # flaky deploys and is what rolled back opshub#85.
  #
  # The previous fix widened the ALB to match the services. This one narrows both, which
  # the earlier comment rejected on the grounds that pinning services "couples each
  # product's service config to this file's slice". That objection is answered by WHERE
  # the slice lives: `local.serving_azs` below drives the ALB subnets AND the exported
  # `private_subnet_ids`, so every product consuming this layer's remote state gets the
  # matching subnets automatically. There is one list, not two that can drift.
  #
  # To go back to multi-AZ, widen `local.serving_azs`. Do not edit this line alone.
  subnet_ids = local.alb_public_subnet_ids

  enable_deletion_protection = false # dev: easy teardown

  tags = { Environment = "develop" }
}
