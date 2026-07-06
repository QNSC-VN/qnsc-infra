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
