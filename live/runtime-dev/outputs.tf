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

# Shared ALB — products attach a host-header listener rule to https_listener_arn.
# NULL while var.enable_alb is false: a product stack reading these fails loudly rather
# than silently attaching to nothing, which is the intended behaviour. rally's develop
# stack no longer reads them at all (it serves through a Cloudflare Tunnel).
output "https_listener_arn" { value = try(module.alb[0].https_listener_arn, null) }
output "http_listener_arn" { value = try(module.alb[0].http_listener_arn, null) }
output "alb_dns_name" { value = try(module.alb[0].dns_name, null) }
# Full ALB ARN. Needed by the shared observability module, which derives the
# CloudWatch `LoadBalancer` dimension (app/<name>/<id>) from it — the listener ARN
# cannot substitute, since it carries an extra listener segment.
output "alb_arn" { value = try(module.alb[0].arn, null) }
output "alb_zone_id" { value = try(module.alb[0].zone_id, null) }

# Shared develop cache. NULL when var.enable_shared_cache is false, so a product stack
# reading these while the node does not exist fails loudly rather than building a URL
# pointing at nothing.
#
# Consume with a database index — see the note on module.shared_cache. The endpoint alone
# is not enough: two products on one node must not share database 0.
output "cache_endpoint" { value = try(module.shared_cache[0].endpoint, null) }
output "cache_port" { value = try(module.shared_cache[0].port, null) }
