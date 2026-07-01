# ── Security Hub — org-wide findings aggregator ────────────────────────────────
# Aggregates findings from GuardDuty, Config, Inspector, Access Analyzer.
# Delegated admin: security-audit account.

# Enable Security Hub in management
resource "aws_securityhub_account" "management" {}

# Delegate admin to security-audit
resource "aws_securityhub_organization_admin_account" "delegate" {
  depends_on       = [aws_securityhub_account.management]
  admin_account_id = var.security_audit_account_id
}

# In security-audit: enable Hub + standards
resource "aws_securityhub_account" "security_audit" {
  provider                 = aws.security_audit
  enable_default_standards = false # we pin versions explicitly below
  depends_on               = [aws_securityhub_organization_admin_account.delegate]
}

# CIS AWS Foundations Benchmark v1.4.0
resource "aws_securityhub_standards_subscription" "cis_v1_4" {
  provider      = aws.security_audit
  depends_on    = [aws_securityhub_account.security_audit]
  standards_arn = "arn:aws:securityhub:ap-southeast-1::standards/cis-aws-foundations-benchmark/v/1.4.0"
}

# AWS Foundational Security Best Practices v1.0.0
resource "aws_securityhub_standards_subscription" "fsbp" {
  provider      = aws.security_audit
  depends_on    = [aws_securityhub_account.security_audit]
  standards_arn = "arn:aws:securityhub:ap-southeast-1::standards/aws-foundational-security-best-practices/v/1.0.0"
}

# Org configuration: auto-enroll new accounts, designate security-audit as aggregator
resource "aws_securityhub_organization_configuration" "this" {
  provider              = aws.security_audit
  depends_on            = [aws_securityhub_account.security_audit]
  auto_enable           = true
  auto_enable_standards = "DEFAULT"

  organization_configuration {
    configuration_type = "CENTRAL"
  }
}

# IAM Access Analyzer — org-wide (finds overly permissive cross-account policies)
resource "aws_accessanalyzer_analyzer" "org" {
  analyzer_name = "qnsc-org-analyzer"
  type          = "ORGANIZATION"
  tags          = merge(var.tags, { Name = "qnsc-org-analyzer" })
}
