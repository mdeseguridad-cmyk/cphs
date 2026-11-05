# Sincronización diaria de empresas (o contratos) y centros de trabajo desde
# los servicios de clientes y organismos. Las integraciones activas están en la
# tabla integracion de la base; sus credenciales, en Secrets Manager bajo
# <proyecto>-<entorno>/integraciones/ (se crean a mano, ver README.md).
#
#   1. Esta programación invoca a la API con {"tipo": "sincronizar"}.
#   2. La API lee las integraciones activas y deja un trabajo por cada una en
#      s3://operaciones/trabajos/.
#   3. La función de trabajos (con internet) consulta el servicio del cliente
#      y deja el resultado en s3://operaciones/importaciones/.
#   4. S3 invoca a la API, que importa con importar_empresas() o
#      importar_centros() en la base: solo toca las empresas y centros de esa
#      integración, marca bajas sin borrar y deja bitácora en sincronizacion.
#
# Corre a las 07:30, cuando la base está encendida en cualquier horario.

locals {
  sincronizacion_cron = {
    siempre         = "cron(30 7 * * ? *)"
    dias_habiles    = "cron(30 7 ? * MON-FRI *)"
    fines_de_semana = "cron(30 7 ? * SAT *)"
  }
}

resource "aws_iam_role" "sincronizacion" {
  count              = local.con_api ? 1 : 0
  name               = "${local.nombre}-sincronizacion"
  assume_role_policy = data.aws_iam_policy_document.asumir_scheduler.json
}

data "aws_iam_policy_document" "sincronizacion" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = local.con_api ? [aws_lambda_function.api[0].arn] : ["*"]
  }
}

resource "aws_iam_role_policy" "sincronizacion" {
  count  = local.con_api ? 1 : 0
  name   = "invocar-api"
  role   = aws_iam_role.sincronizacion[0].id
  policy = data.aws_iam_policy_document.sincronizacion.json
}

resource "aws_scheduler_schedule" "sincronizacion" {
  #checkov:skip=CKV_AWS_297:La programación no contiene datos personales
  count                        = local.con_api ? 1 : 0
  name                         = "${local.nombre}-sincronizacion"
  schedule_expression          = local.sincronizacion_cron[var.horario]
  schedule_expression_timezone = "America/Santiago"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 15
  }

  target {
    arn      = aws_lambda_function.api[0].arn
    role_arn = aws_iam_role.sincronizacion[0].arn
    input    = jsonencode({ tipo = "sincronizar" })
    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}
