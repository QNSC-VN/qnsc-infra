variable "security_audit_account_id" {
  description = "Account ID of the security-audit account (from organization outputs)."
  type        = string
}

variable "log_archive_account_id" {
  description = "Account ID of the log-archive account (from organization outputs)."
  type        = string
}

variable "org_id" {
  description = "AWS Organization ID (from organization outputs, e.g. o-xxxxxxxxxx)."
  type        = string
}

variable "org_root_id" {
  description = "Org root OU ID (from organization outputs, e.g. r-xxxx)."
  type        = string
}

variable "approved_regions" {
  description = "Regions that should be monitored. Must match the organization stack."
  type        = list(string)
  default     = ["ap-southeast-1", "us-east-1"]
}

variable "entra_tenant_id" {
  description = "Microsoft Entra (Azure AD) tenant ID. Used in SSO runbook docs only — actual SAML federation is done in the console/CLI."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Base tags."
  type        = map(string)
  default = {
    Org       = "qnsc"
    ManagedBy = "opentofu"
    Layer     = "security-baseline"
  }
}
