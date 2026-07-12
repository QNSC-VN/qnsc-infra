# =============================================================================
# variables — organization stack.
# =============================================================================

variable "allowed_regions" {
  type        = list(string)
  default     = ["ap-southeast-1", "us-east-1"]
  description = <<-EOT
    Regions the region-lock SCP permits. ap-southeast-1 is the platform home
    region; us-east-1 is retained for global-service operations (ACM for
    CloudFront, some billing/console endpoints). Global services are exempted
    from the lock regardless (see scp.tf NotAction list).
  EOT
}

variable "logging_guardrail_exempt_role_arns" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Principal ARNs exempt from the deny-disable-logging SCP so automation can
    still manage the security-baseline stack. Set to the platform infra-apply
    role(s), e.g. ["arn:aws:iam::<acct>:role/qnsc-github-infra-apply"]. Wildcards
    allowed (ArnNotLike). Empty = no exemption (deny applies to everyone).
  EOT
}

variable "enforce_strict_guardrails" {
  type        = bool
  default     = false
  description = <<-EOT
    Attach the aggressive guardrails (deny-root, deny-iam-user-keys) to the org
    ROOT, covering the management account itself. Enable ONLY after an IAM
    Identity Center admin permission set is assigned to a human — otherwise you
    can lock yourself out of the root user with no non-root admin path.
  EOT
}

variable "enable_identity_center" {
  type        = bool
  default     = false
  description = <<-EOT
    Manage IAM Identity Center (SSO) permission sets. Requires the Identity
    Center instance to be enabled once in the console/CLI first. Account
    assignments are handled in a follow-up (need real user/group IDs).
  EOT
}
