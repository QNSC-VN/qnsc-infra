output "organization_id" {
  description = "AWS Organization ID."
  value       = aws_organizations_organization.this.id
}

output "organization_root_id" {
  description = "Root OU ID."
  value       = aws_organizations_organization.this.roots[0].id
}

output "ou_ids" {
  description = "OU name -> ID."
  value = {
    security       = aws_organizations_organizational_unit.security.id
    infrastructure = aws_organizations_organizational_unit.infrastructure.id
    workloads      = aws_organizations_organizational_unit.workloads.id
    suspended      = aws_organizations_organizational_unit.suspended.id
  }
}

output "account_ids" {
  description = "Account key -> AWS account ID. Downstream stacks assume OrganizationAccountAccessRole into these."
  value       = { for k, a in aws_organizations_account.this : k => a.id }
}

output "account_emails" {
  description = "Account key -> root email (for records)."
  value       = local.account_email
}
