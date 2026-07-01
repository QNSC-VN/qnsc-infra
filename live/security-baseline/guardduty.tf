# ── GuardDuty — org-wide threat detection ─────────────────────────────────────
# Management account: enable + delegate admin to security-audit.
# Security-audit account: configure org-wide auto-enable + protection plans.

# Enable GuardDuty in management (required before delegation)
resource "aws_guardduty_detector" "management" {
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = merge(var.tags, { Account = "management" })
}

# Delegate admin to security-audit account
resource "aws_guardduty_organization_admin_account" "delegate" {
  depends_on       = [aws_guardduty_detector.management]
  admin_account_id = var.security_audit_account_id
}

# In the security-audit account: enable GuardDuty + configure org auto-enroll
resource "aws_guardduty_detector" "security_audit" {
  provider = aws.security_audit
  enable   = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = merge(var.tags, { Account = "security-audit" })
}

# Auto-enable for new member accounts + all protection plans
resource "aws_guardduty_organization_configuration" "this" {
  depends_on                       = [aws_guardduty_organization_admin_account.delegate]
  provider                         = aws.security_audit
  detector_id                      = aws_guardduty_detector.security_audit.id
  auto_enable_organization_members = "ALL"

  datasources {
    s3_logs {
      auto_enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          auto_enable = true
        }
      }
    }
  }
}
