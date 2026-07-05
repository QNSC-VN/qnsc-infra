output "vpc_id" {
  value       = module.network.vpc_id
  description = "Shared dev VPC ID — product infra/live/develop attaches ECS services here."
}

output "public_subnet_ids" {
  value       = module.network.public_subnet_ids
  description = "For each product's own ALB in develop."
}

output "private_subnet_ids" {
  value       = module.network.private_subnet_ids
  description = "For each product's own ECS tasks in develop."
}

output "sg_alb_id" {
  value       = module.network.sg_alb_id
  description = "Shared ALB security group — one per product ALB still created in product repo, reuses this SG."
}

output "sg_app_id" {
  value       = module.network.sg_app_id
  description = "Shared app/ECS security group."
}

output "sg_rds_id" {
  value       = module.network.sg_rds_id
  description = "Shared RDS security group — already allows sg_app_id -> 5432 (see network module)."
}

output "sg_cache_id" {
  value       = module.network.sg_cache_id
  description = "Shared cache security group — already allows sg_app_id -> cache port (see network module)."
}

output "rds_address" {
  value       = module.rds.address
  description = "Shared Postgres instance hostname. Product connects using its own <product>_dev database."
}

output "rds_port" {
  value       = module.rds.port
  description = "Shared Postgres instance port."
}

output "rds_master_secret_arn" {
  value       = module.rds.master_secret_arn
  description = "RDS-managed master credential secret — product CI reads this to build its own db-url secret value (scoped to its own database, not master)."
}

output "cache_endpoint" {
  value       = module.cache.endpoint
  description = "Shared Valkey endpoint — products should namespace keys by product name to avoid collisions."
}

output "cache_port" {
  value       = module.cache.port
  description = "Shared Valkey port."
}
