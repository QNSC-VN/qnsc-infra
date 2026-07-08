# Consumed by every product's prod stack via terraform_remote_state.
# Networking:
output "vpc_id" { value = module.network.vpc_id }
output "public_subnet_ids" { value = module.network.public_subnet_ids }
output "private_subnet_ids" { value = module.network.private_subnet_ids }
output "data_subnet_ids" { value = module.network.data_subnet_ids }

# Security groups (generic, shared across products in this VPC):
output "sg_alb_id" { value = module.network.sg_alb_id }
output "sg_app_id" { value = module.network.sg_app_id }
output "sg_rds_id" { value = module.network.sg_rds_id }
output "sg_cache_id" { value = module.network.sg_cache_id }

# Shared ALB — products attach a host-header listener rule to https_listener_arn:
output "https_listener_arn" { value = module.alb.https_listener_arn }
output "http_listener_arn" { value = module.alb.http_listener_arn }
output "alb_dns_name" { value = module.alb.dns_name }
output "alb_zone_id" { value = module.alb.zone_id }

# Shared cache endpoint (lean tier only; null in ha — cache is per-product then).
output "cache_endpoint" { value = local.is_ha ? null : module.cache[0].endpoint }
output "cache_port" { value = local.is_ha ? null : module.cache[0].port }
