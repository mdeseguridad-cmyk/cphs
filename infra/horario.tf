# Encendido programado de la base de datos (var.horario), en hora de Chile.
#   dias_habiles     lunes a viernes, 07:00–20:00
#   fines_de_semana  sábado 07:00 a domingo 23:00 (la base queda detenida 5
#                    días; RDS la reinicia sola recién a los 7)
# La API (Lambda) no necesita horario: no cobra mientras no recibe
# solicitudes. Fuera de horario responde con error porque no hay base.

locals {
  calendarios = {
    dias_habiles = {
      db_encender = "cron(0 7 ? * MON-FRI *)"
      db_apagar   = "cron(0 20 ? * MON-FRI *)"
    }
    fines_de_semana = {
      db_encender = "cron(0 7 ? * SAT *)"
      db_apagar   = "cron(0 23 ? * SUN *)"
    }
  }
  horario_activo = var.horario != "siempre"

  acciones = local.horario_activo ? {
    db_encender = "arn:aws:scheduler:::aws-sdk:rds:startDBInstance"
    db_apagar   = "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance"
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
  schedule_expression          = local.calendarios[var.horario][each.key]
  schedule_expression_timezone = "America/Santiago"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = each.value
    role_arn = aws_iam_role.horario[0].arn
    input    = jsonencode({ DbInstanceIdentifier = aws_db_instance.principal.identifier })
    retry_policy {
      maximum_retry_attempts = 0 # si ya estaba encendida o apagada, no reintenta
    }
  }
}
