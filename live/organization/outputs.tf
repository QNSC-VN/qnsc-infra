# =============================================================================
# outputs — organization stack.
# =============================================================================

output "organization_id" {
  value       = aws_organizations_organization.this.id
  description = "AWS Organizations ID."
}

output "organization_arn" {
  value       = aws_organizations_organization.this.arn
  description = "AWS Organizations ARN."
}

output "root_id" {
  value       = local.root_id
  description = "Organization root ID (SCP attachment point)."
}

output "ou_ids" {
  value = {
    security        = aws_organizations_organizational_unit.security.id
    shared_services = aws_organizations_organizational_unit.shared_services.id
    workloads       = aws_organizations_organizational_unit.workloads.id
  }
  description = "Organizational Unit IDs — targets for member accounts + SCPs."
}

output "scp_ids" {
  value = {
    region_lock          = aws_organizations_policy.region_lock.id
    deny_disable_logging = aws_organizations_policy.deny_disable_logging.id
    deny_leave_org       = aws_organizations_policy.deny_leave_org.id
    deny_iam_user_keys   = aws_organizations_policy.deny_iam_user_keys.id
    deny_root            = aws_organizations_policy.deny_root.id
  }
  description = "Service Control Policy IDs."
}

output "permission_set_arns" {
  value       = { for k, ps in aws_ssoadmin_permission_set.this : k => ps.arn }
  description = "Identity Center permission set ARNs (empty unless enable_identity_center)."
}
