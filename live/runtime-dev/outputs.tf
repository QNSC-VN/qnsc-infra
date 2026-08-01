# Consumed by every product's develop stack via terraform_remote_state.
# Networking:
output "vpc_id" { value = module.network.vpc_id }
output "public_subnet_ids" { value = module.network.public_subnet_ids }

# SERVING subnets, not every private subnet in the VPC.
#
# Develop's ALB is single-AZ (see `local.serving_azs` in main.tf), and a target in an AZ
# the load balancer has no subnet in is unreachable — it fails its health check and the
# deployment circuit breaker rolls the deploy back. That is not hypothetical: it is what
# broke opshub#85 when these two lists last disagreed.
#
# So this output is deliberately narrowed to the AZs the ALB actually serves. Product
# stacks pass it straight to their ECS services, which means they follow the ALB
# automatically and cannot drift from it. Widening `serving_azs` widens both together.
#
# The VPC itself is unchanged — subnets still exist in all three AZs, so nothing here
# needs new address space to go back to multi-AZ.
output "private_subnet_ids" { value = local.serving_private_subnet_ids }

# Every private subnet, all AZs — for anything that must span the VPC regardless of
# which AZs are serving (there is nothing today; kept so the narrowing above is
# recoverable without a state move).
output "all_private_subnet_ids" { value = module.network.private_subnet_ids }

# Unchanged: RDS and ElastiCache place their own nodes and are not behind the ALB.
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
# Full ALB ARN. Needed by the shared observability module, which derives the
# CloudWatch `LoadBalancer` dimension (app/<name>/<id>) from it — the listener ARN
# cannot substitute, since it carries an extra listener segment.
output "alb_arn" { value = module.alb.arn }
output "alb_zone_id" { value = module.alb.zone_id }
