variable "alert_emails" {
  type        = list(string)
  default     = []
  description = "Emails for cost-anomaly + budget alerts. Empty = create the budget/monitor without email subscribers."
}

variable "monthly_budget_usd" {
  type        = number
  default     = 500
  description = "Account-wide monthly cost budget (USD). Alerts at 80% actual and 100% forecast."
}

variable "anomaly_threshold_usd" {
  type        = number
  default     = 50
  description = "Cost-anomaly alert threshold: notify when total-impact exceeds this USD."
}

variable "enable_config" {
  type = bool
  # FALSE since 2026-08-02. This stack has no .tfvars and CI passes no TF_VAR, so the
  # default IS the deployed setting — a default of true would silently switch recording
  # back on at the next apply.
  default     = false
  description = <<-EOT
    Run AWS Config: the configuration recorder, its delivery channel and the managed
    compliance rules (encrypted volumes, RDS encryption, RDS public-access, IAM user
    policies, CloudTrail enabled, root MFA).

    OFF while the product is internal-team-only and SOC 2 is not being pursued. Config
    bills per configuration item recorded — measured at roughly $19/mo on this account,
    the single largest line after the datastores.

    TURN BACK ON before any SOC 2 / compliance engagement. These are DETECTIVE controls
    (CC7.x), and the history they record CANNOT BE BACKFILLED: an auditor asking "when
    did this bucket become public" gets no answer for any period the recorder was off.
    Turning it on again is one flag; recovering the missing months is not possible.

    CloudTrail, GuardDuty and the audit bucket are NOT gated by this — the audit trail
    itself keeps running. This turns off configuration-state recording only.
  EOT
}

variable "human_users" {
  type        = list(string)
  default     = ["qnsc-base", "sinhhpt"]
  description = <<-EOT
    IAM users created for humans, each holding NO permissions — only self-service MFA and
    the right to assume qnsc-admin or qnsc-developer WITH MFA.

    One entry per person, not one shared account: CloudTrail attributes every role
    assumption to a user, and a shared login destroys that. Removing someone is deleting
    their entry here.

    See human-access.tf for why this exists at all — Identity Center went with the
    organization on 2026-08-18 and a member account cannot enable it — and for the honest
    limitation: there is no central directory here, so past a handful of people this should
    be replaced by federating the existing Entra tenant to IAM.
  EOT
}
