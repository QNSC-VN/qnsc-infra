# =============================================================================
# platform-dev — shared network + database + cache for ALL products' develop
# environments. Prod stays fully isolated per-product (see docs/shared-modules-migration.md
# and each product's infra/live/prod/); this stack exists because dev-tier
# traffic is low/spiky by nature and doesn't need per-product dedicated infra.
#
# Product infra repos consume this stack's outputs via terraform_remote_state
# (same pattern already used for platform/bootstrap) instead of provisioning
# their own VPC/NAT/RDS/cache in infra/live/develop/.
#
# Per-product databases are NOT created by Terraform here (would require the
# RDS instance to be reachable from GitHub-hosted CI runners, which means a
# public subnet — a real exception to how every RDS instance in this org is
# set up). Instead, each product's own migrator task (already runs inside
# this VPC on every deploy) runs `CREATE DATABASE IF NOT EXISTS <product>_dev`
# as its first step before applying schema migrations. RDS instance stays in
# private data subnets like every other instance in the org — no exception.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/platform-dev/terraform.tfstate"
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

locals {
  region = "ap-southeast-1"
  azs    = ["ap-southeast-1a", "ap-southeast-1b"]
  name   = "platform-dev"
}

# ── Read bootstrap outputs (KMS key) ─────────────────────────────────────────
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# ── Shared VPC + single NAT instance (dev-tier egress) ───────────────────────
module "network" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/network?ref=network-v1.1.2"

  name   = local.name
  region = local.region
  azs    = local.azs

  vpc_cidr             = "10.90.0.0/16"
  public_subnet_cidrs  = ["10.90.0.0/24", "10.90.1.0/24"]
  private_subnet_cidrs = ["10.90.10.0/24", "10.90.11.0/24"]
  data_subnet_cidrs    = ["10.90.20.0/24", "10.90.21.0/24"]

  nat_type                   = "instance" # fck-nat, ~$3/mo — dev only, matches existing per-product dev pattern
  enable_interface_endpoints = false      # already has a NAT; endpoints would be redundant cost
  enable_flow_logs           = false      # dev-tier, no SOC2 requirement (prod keeps flow logs)
  flow_log_retention_days    = 7

  tags = { Layer = "platform", Environment = "develop" }
}

# ── Shared Postgres instance — one instance, one database per product ───────
# db_name is the platform's own bootstrap database only. Products create their
# own "<product>_dev" database from inside the VPC via their migrator task
# (see file header) — Terraform doesn't own per-product database creation.
module "rds" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/rds?ref=rds-v1.0.1"

  identifier        = local.name
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_rds_id
  kms_key_arn       = data.terraform_remote_state.platform.outputs.kms_key_arn

  instance_class           = "db.t4g.small" # shared by N products' dev traffic — bump if contention shows up
  allocated_storage_gb     = 20
  max_allocated_storage_gb = 100
  multi_az                 = false
  deletion_protection      = false
  backup_retention_days    = 3
  monitoring_interval      = 0
  db_name                  = "platform"

  tags = { Layer = "platform", Environment = "develop", AutoStop = "true" }
}

# ── Shared Valkey — one small node, all products' dev cache traffic ─────────
module "cache" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/cache?ref=cache-v1.0.0"

  name              = local.name
  mode              = "node"
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_cache_id

  tags = { Layer = "platform", Environment = "develop" }
}

# ── Dev cost saver: stop shared RDS + NAT instance off-hours ─────────────────
# Acts on resources tagged AutoStop=true (rds above, NAT instance tagged
# automatically by the network module). ECS scale-down stays per-product,
# configured in each product's own infra/live/develop/.
module "dev_scheduler" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/dev-scheduler?ref=dev-scheduler-v1.0.0"
  name   = local.name
  tags   = { Layer = "platform", Environment = "develop" }
}
