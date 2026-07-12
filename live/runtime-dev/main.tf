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
# Dev has NO shared cache: each product runs a Valkey sidecar inside its task
# (single-task dev), so this stack is network + ingress only. RDS and Fargate
# are always per-product and never live here.
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
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/alb?ref=alb-v1.0.0"

  name               = local.name
  security_group_ids = [module.network.sg_alb_id]
  subnet_ids         = module.network.public_subnet_ids
  certificate_arn    = data.terraform_remote_state.edge.outputs.acm_cert_arn

  enable_deletion_protection = false # dev: easy teardown

  tags = { Environment = "develop" }
}
