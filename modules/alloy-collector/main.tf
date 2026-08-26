terraform {
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.0" }
  }
}

locals {
  name = "observability-alloy"
  tags = merge(var.tags, { Component = "alloy-collector" })
}

# ── Cloudflare Tunnel ingress ─────────────────────────────────────────────────
# Same shared module every product's own tunnel uses (modules/cf-tunnel), so this
# collector is provisioned the identical way rather than a bespoke one-off.
# cloudflared dials OUT — the task opens no inbound port, needs no ALB, and the
# security group below carries no ingress rule at all.
module "tunnel" {
  source = "git::https://github.com/QNSC-VN/qnsc-tf-modules.git//modules/cf-tunnel?ref=cf-tunnel-v0.1.1"

  account_id = var.cloudflare_account_id
  name       = local.name
  hostname   = var.tunnel_hostname
  # Alloy's OTLP/HTTP receiver — chosen over the gRPC receiver because a
  # Cloudflare Tunnel proxies HTTP/1.1 cleanly; gRPC through the same tunnel
  # needs an explicit h2 upgrade this module doesn't carry. Every product's
  # OTEL_EXPORTER_OTLP_PROTOCOL is http/protobuf for this reason.
  service = "http://localhost:4318"
}

resource "aws_secretsmanager_secret" "tunnel_token" {
  name                    = "platform/observability/tunnel-token"
  description             = "Cloudflare Tunnel connector token for the shared Alloy collector. Managed by Terraform — do not edit by hand."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "tunnel_token" {
  secret_id     = aws_secretsmanager_secret.tunnel_token.id
  secret_string = module.tunnel.token
}

# ── Grafana Cloud push credentials ──────────────────────────────────────────────
# One secret, several keys — Alloy's remote_write/loki/otlp exporter blocks each
# read one key out of it. Populated by Terraform from live/observability's
# grafana_cloud_stack outputs, never pasted in by hand.
resource "aws_secretsmanager_secret" "grafana_push" {
  name                    = "platform/observability/grafana-push"
  description             = "Grafana Cloud push credentials (Mimir/Loki/Tempo). Managed by Terraform — do not edit by hand."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "grafana_push" {
  secret_id = aws_secretsmanager_secret.grafana_push.id
  secret_string = jsonencode({
    prometheus_url      = var.prometheus_remote_write_url
    prometheus_username = var.prometheus_username
    loki_url            = var.loki_url
    loki_username       = var.loki_username
    tempo_url           = var.tempo_url
    tempo_username      = var.tempo_username
    push_token          = var.grafana_cloud_push_token
  })
}

# ── Ingress auth: Cloudflare Access Service Token ────────────────────────────
# Cloudflare's own gate, not a hand-rolled bearer check inside Alloy — the
# Access Application sits in front of the tunnel hostname and the collector
# never sees a request that didn't already present a valid service token.
# Every product's OTLP exporter sends the pair as CF-Access-Client-Id /
# CF-Access-Client-Secret headers; Alloy itself stays unaware any of this
# exists, same as the tunnel dial-out.
resource "cloudflare_zero_trust_access_application" "otlp" {
  account_id       = var.cloudflare_account_id
  name             = "Observability OTLP ingest"
  domain           = var.tunnel_hostname
  type             = "self_hosted"
  session_duration = "24h"
}

resource "cloudflare_zero_trust_access_service_token" "otlp" {
  account_id = var.cloudflare_account_id
  name       = "otlp-collector-products"
}

resource "cloudflare_zero_trust_access_policy" "otlp" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.otlp.id
  name           = "service-token-only"
  precedence     = 1
  decision       = "non_identity"

  include {
    service_token = [cloudflare_zero_trust_access_service_token.otlp.id]
  }
}

resource "aws_secretsmanager_secret" "otlp_access_token" {
  name                    = "platform/observability/otlp-access-token"
  description             = "Cloudflare Access service token products present to reach the OTLP endpoint. Managed by Terraform — do not edit by hand."
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "otlp_access_token" {
  secret_id = aws_secretsmanager_secret.otlp_access_token.id
  secret_string = jsonencode({
    client_id     = cloudflare_zero_trust_access_service_token.otlp.client_id
    client_secret = cloudflare_zero_trust_access_service_token.otlp.client_secret
  })
}

# ── Networking ───────────────────────────────────────────────────────────────
# Egress-only. No ALB, no listener, no ingress rule — cloudflared is the only
# path in, and it dials out.
resource "aws_security_group" "alloy" {
  name_prefix = "${local.name}-"
  description = "Alloy collector task — egress only, ingress via Cloudflare Tunnel."
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ── Logging ──────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "alloy" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = local.tags
}

# ── IAM ──────────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "assume_ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.tunnel_token.arn,
      aws_secretsmanager_secret.grafana_push.arn,
    ]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${local.name}-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
  tags               = local.tags
}

# Read-only, and scoped to metrics — this is the CloudWatch bridge for the ALB
# dimension folded into Mimir. Nothing here can modify or delete a metric,
# alarm, or log; it only lists and reads what already exists.
data "aws_iam_policy_document" "task_cloudwatch_read" {
  statement {
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_cloudwatch_read" {
  name   = "${local.name}-cloudwatch-read"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_cloudwatch_read.json
}

# ── Task definition ──────────────────────────────────────────────────────────
# Two containers, one task, one network namespace (awsvpc): cloudflared reaches
# Alloy over localhost, exactly like every product's api reaches its own
# cloudflared sidecar the other direction.
#
# Alloy's config is inlined via `command`, not a custom image. This is a shared
# platform service with one config, not a product with a build pipeline —
# baking a config into an image here would mean standing up an ECR repo and a
# build workflow for a file that changes far less often than any product's code.
resource "aws_ecs_task_definition" "alloy" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "alloy"
      image     = "grafana/alloy:v1.5.1"
      essential = true

      # Written to disk at container start, not baked into an image — see the
      # comment above the resource. AWS_REGION is set by the ECS agent already;
      # the CloudWatch exporter reads it from the standard SDK chain.
      entryPoint = ["sh", "-c"]
      command = [
        <<-EOT
        cat <<'ALLOY_CONFIG' > /etc/alloy/config.alloy
        ${templatefile("${path.module}/config.alloy.tftpl", {
        alb_arns = var.alb_arns
    })}
        ALLOY_CONFIG
        exec /bin/alloy run /etc/alloy/config.alloy --server.http.listen-addr=0.0.0.0:12345 --storage.path=/var/lib/alloy/data
        EOT
  ]

  # Each key pulled straight out of the one JSON secret via ECS's own
  # "<arn>:<key>::" bundle syntax — no JSON parsing inside Alloy's config,
  # just plain env vars river reads with sys.env().
  secrets = [
    { name = "PROM_URL", valueFrom = "${aws_secretsmanager_secret.grafana_push.arn}:prometheus_url::" },
    { name = "PROM_USER", valueFrom = "${aws_secretsmanager_secret.grafana_push.arn}:prometheus_username::" },
    { name = "LOKI_URL", valueFrom = "${aws_secretsmanager_secret.grafana_push.arn}:loki_url::" },
    { name = "LOKI_USER", valueFrom = "${aws_secretsmanager_secret.grafana_push.arn}:loki_username::" },
    { name = "TEMPO_URL", valueFrom = "${aws_secretsmanager_secret.grafana_push.arn}:tempo_url::" },
    { name = "TEMPO_USER", valueFrom = "${aws_secretsmanager_secret.grafana_push.arn}:tempo_username::" },
    { name = "PUSH_TOKEN", valueFrom = "${aws_secretsmanager_secret.grafana_push.arn}:push_token::" },
  ]

  portMappings = [
    { containerPort = 4318, protocol = "tcp" },  # OTLP/HTTP, tunnel target
    { containerPort = 12345, protocol = "tcp" }, # Alloy UI, localhost-only in practice
  ]

  logConfiguration = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.alloy.name
      "awslogs-region"        = data.aws_region.current.name
      "awslogs-stream-prefix" = "alloy"
    }
  }
},
{
  name      = "cloudflared"
  image     = "cloudflare/cloudflared:2026.1.0"
  essential = true
  command   = ["tunnel", "--no-autoupdate", "run", "--token", "$(TUNNEL_TOKEN)"]

  secrets = [
    { name = "TUNNEL_TOKEN", valueFrom = aws_secretsmanager_secret.tunnel_token.arn },
  ]

  logConfiguration = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.alloy.name
      "awslogs-region"        = data.aws_region.current.name
      "awslogs-stream-prefix" = "cloudflared"
    }
  }
}
])

tags = local.tags
}

data "aws_region" "current" {}

# ── Service ──────────────────────────────────────────────────────────────────
# Always one task, never idled. This is shared infrastructure every product's
# telemetry depends on continuously — it does not get the idle_schedule
# treatment the product develop stacks use, and there is deliberately no
# autoscaling: one small Fargate task is enough for this org's volume, and a
# scale-out later needs the trace-affinity note in the design doc first
# (tail sampling requires all of one trace's spans to reach the same replica).
resource "aws_ecs_service" "alloy" {
  name            = local.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.alloy.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.alloy.id]
    assign_public_ip = false
  }

  tags = local.tags
}
