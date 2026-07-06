# ── Cost governance — account budget + anomaly detection (both free) ─────────
# AWS Budgets (first 2 free) + Cost Anomaly Detection (free) give proactive
# spend alerts. Per-product/per-env breakdown comes from cost-allocation tags
# (Project / Environment) in Cost Explorer — no per-account split required.

resource "aws_budgets_budget" "account_monthly" {
  name         = "qnsc-account-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = length(var.alert_emails) > 0 ? [80, 100] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value >= 100 ? "FORECASTED" : "ACTUAL"
      subscriber_email_addresses = var.alert_emails
    }
  }
}

# Detect unusual spend per service.
resource "aws_ce_anomaly_monitor" "services" {
  name              = "qnsc-service-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "alerts" {
  count = length(var.alert_emails) > 0 ? 1 : 0

  name             = "qnsc-anomaly-alerts"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }

  dynamic "subscriber" {
    for_each = var.alert_emails
    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }
}
