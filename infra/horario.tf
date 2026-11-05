# Encendido programado (var.horario), en hora de Chile. La base se enciende
# 30 minutos antes que la API y se apaga 15 minutos después.
#   dias_habiles     lunes a viernes, 07:30–19:30
#   fines_de_semana  sábado 07:30 a domingo 23:00 (la base queda detenida 5
#                    días; RDS la reinicia sola recién a los 7)
# El balanceador, NAT y almacenamiento se siguen cobrando igual.

locals {
  calendarios = {
    dias_habiles = {
      db_encender  = "cron(0 7 ? * MON-FRI *)"
      api_encender = "cron(30 7 ? * MON-FRI *)"
      api_apagar   = "cron(30 19 ? * MON-FRI *)"
      db_apagar    = "cron(45 19 ? * MON-FRI *)"
    }
    fines_de_semana = {
      db_encender  = "cron(0 7 ? * SAT *)"
      api_encender = "cron(30 7 ? * SAT *)"
      api_apagar   = "cron(0 23 ? * SUN *)"
      db_apagar    = "cron(15 23 ? * SUN *)"
    }
  }
  horario_activo = var.horario != "siempre"
  calendario     = local.horario_activo ? local.calendarios[var.horario] : {}

  acciones = local.horario_activo ? {
    db_encender = {
      destino = "arn:aws:scheduler:::aws-sdk:rds:startDBInstance"
      entrada = jsonencode({ DbInstanceIdentifier = aws_db_instance.principal.identifier })
    }
    db_apagar = {
      destino = "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance"
      entrada = jsonencode({ DbInstanceIdentifier = aws_db_instance.principal.identifier })
    }
    api_encender = {
      destino = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
      entrada = jsonencode({ Cluster = aws_ecs_cluster.principal.name, Service = aws_ecs_service.api.name, DesiredCount = local.api_tareas })
    }
    api_apagar = {
      destino = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
      entrada = jsonencode({ Cluster = aws_ecs_cluster.principal.name, Service = aws_ecs_service.api.name, DesiredCount = 0 })
    }
  } : {}
}

data "aws_iam_policy_document" "asumir_scheduler" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.actual.account_id]
    }
  }
}

resource "aws_iam_role" "horario" {
  count              = local.horario_activo ? 1 : 0
  name               = "${local.nombre}-horario"
  assume_role_policy = data.aws_iam_policy_document.asumir_scheduler.json
}

data "aws_iam_policy_document" "horario" {
  statement {
    actions   = ["rds:StartDBInstance", "rds:StopDBInstance"]
    resources = [aws_db_instance.principal.arn]
  }
  statement {
    actions   = ["ecs:UpdateService"]
    resources = [aws_ecs_service.api.id]
  }
}

resource "aws_iam_role_policy" "horario" {
  count  = local.horario_activo ? 1 : 0
  name   = "encender-apagar"
  role   = aws_iam_role.horario[0].id
  policy = data.aws_iam_policy_document.horario.json
}

resource "aws_scheduler_schedule" "horario" {
  #checkov:skip=CKV_AWS_297:Las programaciones no contienen datos personales
  for_each                     = local.acciones
  name                         = "${local.nombre}-${replace(each.key, "_", "-")}"
  schedule_expression          = local.calendario[each.key]
  schedule_expression_timezone = "America/Santiago"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = each.value.destino
    role_arn = aws_iam_role.horario[0].arn
    input    = each.value.entrada # JSON por acción: así DesiredCount queda como número
    retry_policy {
      maximum_retry_attempts = 0 # si ya estaba encendida o apagada, no reintenta
    }
  }
}
