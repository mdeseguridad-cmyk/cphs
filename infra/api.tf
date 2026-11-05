# API en AWS Lambda, con la misma imagen de contenedor que correría en
# cualquier otro lado: Lambda Web Adapter traduce las invocaciones a HTTP.
#
#   api        en la VPC (subredes privadas). CloudFront la llama por su URL
#              de función, firmada (OAC); nadie más puede invocarla. Llega a
#              la base y a S3, y a nada más.
#   trabajos   fuera de la VPC. Hace lo que necesita internet: enviar
#              correos (SES), administrar usuarios (Cognito) y consultar los
#              servicios de empresas y centros de clientes y organismos. La
#              API le deja trabajos en s3://operaciones/trabajos/ y S3 la
#              invoca; los resultados de los servicios vuelven a la API por
#              s3://operaciones/importaciones/ (integraciones.tf).
#
# Mientras no exista la imagen de la aplicación (var.api_imagen vacía), las
# funciones no se crean y CloudFront solo sirve el front.

locals {
  con_api               = var.api_imagen != ""
  prefijo_trabajos      = "trabajos/"
  prefijo_importaciones = "importaciones/"
  prefijo_secretos      = "${local.nombre}/integraciones/"
  db_usuario_app        = "paritario_app"
  cognito_emisor        = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.principal.id}"
  correo_remitente      = var.dominio_correo != "" ? "notificaciones@${var.dominio_correo}" : ""

  entorno_comun = {
    AWS_LWA_PORT                 = tostring(var.api_puerto)
    AWS_LWA_READINESS_CHECK_PATH = var.api_ruta_salud
    DOCUMENTOS_BUCKET            = aws_s3_bucket.b["documentos"].bucket
    OPERACIONES_BUCKET           = aws_s3_bucket.b["operaciones"].bucket
    TRABAJOS_PREFIJO             = local.prefijo_trabajos
    IMPORTACIONES_PREFIJO        = local.prefijo_importaciones
    INTEGRACIONES_SECRETOS       = local.prefijo_secretos
    COGNITO_DOMINIO              = local.federado ? "https://${aws_cognito_user_pool_domain.principal[0].domain}.auth.${var.region}.amazoncognito.com" : ""
    COGNITO_USER_POOL_ID         = aws_cognito_user_pool.principal.id
    COGNITO_CLIENT_ID            = aws_cognito_user_pool_client.spa.id
    COGNITO_EMISOR               = local.cognito_emisor
    CORREO_REMITENTE             = local.correo_remitente
  }
}

resource "aws_ecr_repository" "api" {
  #checkov:skip=CKV_AWS_136:Cifrado AES-256 por defecto de ECR; las imágenes no contienen datos personales
  name                 = "${local.nombre}-api"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar las 20 imágenes más recientes"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# Lambda baja la imagen con estos permisos, solo para funciones de esta cuenta.
data "aws_iam_policy_document" "ecr_lambda" {
  statement {
    sid = "LambdaBajaLaImagen"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    condition {
      test     = "StringLike"
      variable = "aws:sourceArn"
      values   = ["arn:aws:lambda:${var.region}:${data.aws_caller_identity.actual.account_id}:function:${local.nombre}-*"]
    }
  }
}

resource "aws_ecr_repository_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy     = data.aws_iam_policy_document.ecr_lambda.json
}

# --- Registros (30 días, por minimización de datos) ------------------------

resource "aws_cloudwatch_log_group" "funcion" {
  #checkov:skip=CKV_AWS_338:30 días por minimización de datos personales (Ley 21.719)
  #checkov:skip=CKV_AWS_158:Cifrado por defecto de CloudWatch; llave propia recomendada para producción
  for_each          = toset(["api", "trabajos"])
  name              = "/aws/lambda/${local.nombre}-${each.key}"
  retention_in_days = 30
}

# --- Roles -----------------------------------------------------------------

data "aws_iam_policy_document" "asumir_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# API: conectarse a la base como paritario_app, leer y escribir documentos y
# dejar trabajos. No puede enviar correos ni tocar usuarios de Cognito.
resource "aws_iam_role" "api" {
  name               = "${local.nombre}-api"
  assume_role_policy = data.aws_iam_policy_document.asumir_lambda.json
}

resource "aws_iam_role_policy_attachment" "api_vpc" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "api" {
  statement {
    sid       = "BaseDeDatos"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${var.region}:${data.aws_caller_identity.actual.account_id}:dbuser:${aws_db_instance.principal.resource_id}/${local.db_usuario_app}"]
  }
  statement {
    sid       = "Documentos"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.b["documentos"].arn}/*"]
  }
  statement {
    sid       = "ListarDocumentos"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.b["documentos"].arn]
  }
  statement {
    sid       = "DejarTrabajos"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.b["operaciones"].arn}/${local.prefijo_trabajos}*"]
  }
  statement {
    sid       = "LeerImportaciones"
    actions   = ["s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.b["operaciones"].arn}/${local.prefijo_importaciones}*"]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "api"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

# Trabajos: leer y borrar trabajos, adjuntar documentos, enviar correos y
# administrar usuarios del user pool. No llega a la base de datos.
resource "aws_iam_role" "trabajos" {
  name               = "${local.nombre}-trabajos"
  assume_role_policy = data.aws_iam_policy_document.asumir_lambda.json
}

resource "aws_iam_role_policy_attachment" "trabajos_basica" {
  role       = aws_iam_role.trabajos.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "trabajos" {
  statement {
    sid       = "LeerTrabajos"
    actions   = ["s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.b["operaciones"].arn}/${local.prefijo_trabajos}*"]
  }
  statement {
    sid       = "DejarImportaciones"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.b["operaciones"].arn}/${local.prefijo_importaciones}*"]
  }
  statement {
    sid       = "CredencialesDeClientes"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.actual.account_id}:secret:${local.prefijo_secretos}*"]
  }
  statement {
    sid       = "AdjuntarDocumentos"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.b["documentos"].arn}/*"]
  }
  statement {
    sid       = "Correo"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = [var.dominio_correo != "" ? "*@${var.dominio_correo}" : "*"]
    }
  }
  statement {
    sid = "Usuarios"
    actions = [
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminGetUser",
      "cognito-idp:AdminUpdateUserAttributes",
      "cognito-idp:AdminDisableUser",
      "cognito-idp:AdminEnableUser",
      "cognito-idp:AdminResetUserPassword",
      "cognito-idp:AdminUserGlobalSignOut",
    ]
    resources = [aws_cognito_user_pool.principal.arn]
  }
}

resource "aws_iam_role_policy" "trabajos" {
  name   = "trabajos"
  role   = aws_iam_role.trabajos.id
  policy = data.aws_iam_policy_document.trabajos.json
}

# --- Funciones ---------------------------------------------------------------

resource "aws_lambda_function" "api" {
  #checkov:skip=CKV_AWS_116:Las solicitudes HTTP se responden en línea; no hay invocaciones asíncronas que reintentar
  #checkov:skip=CKV_AWS_173:Las variables no contienen secretos (la base usa tokens de IAM); cifradas con la llave de AWS
  #checkov:skip=CKV_AWS_272:Firma de código recomendada para producción
  #checkov:skip=CKV_AWS_50:X-Ray necesita salida a internet o un endpoint de pago desde la VPC
  #checkov:skip=CKV_AWS_115:Concurrencia configurable (var.api_concurrencia); las cuentas nuevas parten con un máximo de 10
  count         = local.con_api ? 1 : 0
  function_name = "${local.nombre}-api"
  role          = aws_iam_role.api.arn
  package_type  = "Image"
  image_uri     = var.api_imagen
  architectures = ["arm64"] # Graviton: ~20 % más barato
  memory_size   = var.api_memoria
  timeout       = var.api_tiempo_max

  reserved_concurrent_executions = var.api_concurrencia

  vpc_config {
    subnet_ids         = aws_subnet.privada[*].id
    security_group_ids = [aws_security_group.api.id]
  }

  environment {
    variables = merge(local.entorno_comun, {
      DB_HOST    = aws_db_instance.principal.address
      DB_PORT    = tostring(aws_db_instance.principal.port)
      DB_NAME    = aws_db_instance.principal.db_name
      DB_USER    = local.db_usuario_app
      DB_AUTH    = "iam"
      DB_SSLMODE = "verify-full"
      # Eventos que no son HTTP (programación diaria, importaciones desde S3)
      # llegan a la aplicación como POST a esta ruta, que CloudFront no expone.
      AWS_LWA_PASS_THROUGH_PATH = "/interno/eventos"
    })
  }

  depends_on = [aws_cloudwatch_log_group.funcion, aws_ecr_repository_policy.api, aws_iam_role_policy_attachment.api_vpc]
}

resource "aws_lambda_function_url" "api" {
  count              = local.con_api ? 1 : 0
  function_name      = aws_lambda_function.api[0].function_name
  authorization_type = "AWS_IAM" # solo CloudFront, que firma cada solicitud
  invoke_mode        = "BUFFERED"
}

resource "aws_lambda_permission" "cloudfront_url" {
  count                  = local.con_api ? 1 : 0
  statement_id           = "CloudFrontUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api[0].function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.principal.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "cloudfront_invocar" {
  count         = local.con_api ? 1 : 0
  statement_id  = "CloudFrontInvocar"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api[0].function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.principal.arn
}

resource "aws_lambda_function" "trabajos" {
  #checkov:skip=CKV_AWS_117:Fuera de la VPC a propósito: necesita SES y Cognito sin NAT Gateway, y no llega a la base
  #checkov:skip=CKV_AWS_116:S3 la invoca de forma asíncrona; los trabajos fallidos quedan en el bucket hasta que vencen (7 días)
  #checkov:skip=CKV_AWS_173:Las variables no contienen secretos; cifradas con la llave de AWS
  #checkov:skip=CKV_AWS_272:Firma de código recomendada para producción
  #checkov:skip=CKV_AWS_50:Trazas de X-Ray recomendadas para producción
  count         = local.con_api ? 1 : 0
  function_name = "${local.nombre}-trabajos"
  role          = aws_iam_role.trabajos.arn
  package_type  = "Image"
  image_uri     = var.api_imagen
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 60

  reserved_concurrent_executions = var.api_concurrencia == -1 ? -1 : 2

  environment {
    variables = merge(local.entorno_comun, {
      # Lambda Web Adapter entrega los eventos de S3 como POST a esta ruta.
      AWS_LWA_PASS_THROUGH_PATH = "/interno/trabajos"
      MODO                      = "trabajos"
    })
  }

  depends_on = [aws_cloudwatch_log_group.funcion, aws_ecr_repository_policy.api, aws_iam_role_policy_attachment.trabajos_basica]
}

resource "aws_lambda_permission" "s3_trabajos" {
  count          = local.con_api ? 1 : 0
  statement_id   = "S3Trabajos"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.trabajos[0].function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.b["operaciones"].arn
  source_account = data.aws_caller_identity.actual.account_id
}

resource "aws_lambda_permission" "s3_importaciones" {
  count          = local.con_api ? 1 : 0
  statement_id   = "S3Importaciones"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.api[0].function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.b["operaciones"].arn
  source_account = data.aws_caller_identity.actual.account_id
}

# Un bucket tiene una sola configuración de notificaciones: trabajos van a la
# función de trabajos; importaciones, a la API (que escribe en la base).
resource "aws_s3_bucket_notification" "operaciones" {
  count  = local.con_api ? 1 : 0
  bucket = aws_s3_bucket.b["operaciones"].id
  lambda_function {
    lambda_function_arn = aws_lambda_function.trabajos[0].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = local.prefijo_trabajos
  }
  lambda_function {
    lambda_function_arn = aws_lambda_function.api[0].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = local.prefijo_importaciones
  }
  depends_on = [aws_lambda_permission.s3_trabajos, aws_lambda_permission.s3_importaciones]
}
