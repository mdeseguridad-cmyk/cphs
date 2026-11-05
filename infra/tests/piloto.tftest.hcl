# Pruebas de la lógica de la infraestructura con un proveedor simulado: no
# requieren credenciales ni crean recursos. Ejecutar con: terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["sa-east-1a", "sa-east-1b", "sa-east-1c"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      arn                = "arn:aws:rds:sa-east-1:123456789012:db:paritario-piloto"
      resource_id        = "db-SIMULADA"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:sa-east-1:123456789012:secret:rds-admin", kms_key_id = "k", secret_status = "active" }]
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::bucket-simulado" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/simulado" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:sa-east-1:123456789012:task-definition/simulada:1" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = { arn = "arn:aws:cloudfront::123456789012:distribution/SIMULADA" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:sa-east-1:123456789012:cluster/paritario-piloto", id = "arn:aws:ecs:sa-east-1:123456789012:cluster/paritario-piloto" }
  }
  mock_resource "aws_ecr_repository" {
    defaults = { arn = "arn:aws:ecr:sa-east-1:123456789012:repository/paritario-piloto-api", repository_url = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/paritario-piloto-api" }
  }
  mock_resource "aws_sesv2_email_identity" {
    defaults = { arn = "arn:aws:ses:sa-east-1:123456789012:identity/paritario.cl", dkim_signing_attributes = [{ tokens = ["tok1", "tok2", "tok3"] }] }
  }
  mock_resource "aws_cognito_user_pool" {
    defaults = { arn = "arn:aws:cognito-idp:sa-east-1:123456789012:userpool/sa-east-1_SIMULADO", id = "sa-east-1_SIMULADO" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:sa-east-1:123456789012:log-group:simulado" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:sa-east-1:123456789012:function:simulada" }
  }
  mock_resource "aws_lambda_function_url" {
    defaults = { function_url = "https://abc123simulado.lambda-url.sa-east-1.on.aws/" }
  }
  mock_resource "aws_vpc_endpoint" {
    defaults = { prefix_list_id = "pl-6aa54003" }
  }
  mock_resource "aws_cloudfront_function" {
    defaults = { arn = "arn:aws:cloudfront::123456789012:function/simulada" }
  }
}

run "piloto_sin_aplicacion" {
  command = apply
  variables {
    correo_alertas = "alertas@ejemplo.cl"
  }

  assert {
    condition     = length(aws_lambda_function.api) == 0 && length(aws_lambda_function.trabajos) == 0
    error_message = "Sin imagen de la API no se crean las funciones."
  }
  assert {
    condition     = length(aws_cloudfront_distribution.principal.origin) == 1 && length(aws_cloudfront_distribution.principal.ordered_cache_behavior) == 0
    error_message = "Sin API, CloudFront solo debe servir el front."
  }
  assert {
    condition     = length(aws_scheduler_schedule.horario) == 0
    error_message = "Con horario 'siempre' no debe haber encendido programado."
  }
  assert {
    condition     = aws_db_instance.principal.publicly_accessible == false && aws_db_instance.principal.storage_encrypted
    error_message = "La base debe ser privada y cifrada."
  }
  assert {
    condition     = aws_db_instance.principal.deletion_protection && aws_db_instance.principal.iam_database_authentication_enabled
    error_message = "La base debe tener protección contra borrado y autenticación por IAM."
  }
  assert {
    condition     = length(aws_budgets_budget.mensual) == 1
    error_message = "Con correo de alertas debe existir el presupuesto."
  }
  assert {
    condition     = length(aws_sesv2_email_identity.dominio) == 0
    error_message = "Sin dominio de correo no se configura SES."
  }
  assert {
    condition     = aws_cloudfront_distribution.principal.viewer_certificate[0].cloudfront_default_certificate
    error_message = "Sin dominio propio se usa el certificado de CloudFront."
  }
  assert {
    condition     = length([for s in aws_subnet.privada : s if s.map_public_ip_on_launch]) == 0
    error_message = "Las subredes privadas no deben asignar IP pública."
  }
  assert {
    condition     = length([for r in aws_route_table.privada.route : r if r.cidr_block == "0.0.0.0/0"]) == 0
    error_message = "Las subredes privadas no deben tener ruta a internet."
  }
  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway"
    error_message = "S3 debe alcanzarse por un endpoint gateway (sin costo)."
  }
}

run "con_aplicacion_y_dias_habiles" {
  command = apply
  variables {
    api_imagen       = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/paritario-piloto-api:1.0.0"
    api_concurrencia = 10
    horario          = "dias_habiles"
  }

  assert {
    condition     = aws_lambda_function.api[0].architectures[0] == "arm64" && aws_lambda_function.api[0].image_uri == "123456789012.dkr.ecr.sa-east-1.amazonaws.com/paritario-piloto-api:1.0.0"
    error_message = "La API debe correr la imagen pedida en ARM64."
  }
  assert {
    condition     = length(aws_lambda_function.api[0].vpc_config) == 1 && length(aws_lambda_function.trabajos[0].vpc_config) == 0
    error_message = "La API va en la VPC; la función de trabajos, fuera."
  }
  assert {
    condition     = aws_lambda_function.api[0].reserved_concurrent_executions == 10
    error_message = "La concurrencia reservada debe respetar api_concurrencia."
  }
  assert {
    condition     = aws_lambda_function.api[0].environment[0].variables["DB_USER"] == "paritario_app" && aws_lambda_function.api[0].environment[0].variables["DB_AUTH"] == "iam"
    error_message = "La API debe conectarse como paritario_app con token de IAM."
  }
  assert {
    condition     = length([for k, v in aws_lambda_function.api[0].environment[0].variables : k if strcontains(lower(k), "password")]) == 0
    error_message = "La API no debe recibir claves en sus variables."
  }
  assert {
    condition     = !contains(keys(aws_lambda_function.trabajos[0].environment[0].variables), "DB_HOST")
    error_message = "La función de trabajos no debe conocer la base."
  }
  assert {
    condition     = aws_lambda_function_url.api[0].authorization_type == "AWS_IAM"
    error_message = "La URL de la función solo debe aceptar solicitudes firmadas."
  }
  assert {
    condition     = one([for o in aws_cloudfront_distribution.principal.origin : o.domain_name if o.origin_id == "api"]) == "abc123simulado.lambda-url.sa-east-1.on.aws"
    error_message = "CloudFront debe apuntar al dominio de la URL de la función."
  }
  assert {
    condition     = aws_cloudfront_distribution.principal.ordered_cache_behavior[0].path_pattern == "/api/*"
    error_message = "/api/* debe ir a la función."
  }
  assert {
    condition     = aws_s3_bucket_notification.trabajos[0].lambda_function[0].filter_prefix == "trabajos/"
    error_message = "Los trabajos se leen desde el prefijo trabajos/."
  }
  assert {
    condition     = length(aws_scheduler_schedule.horario) == 2
    error_message = "El horario solo enciende y apaga la base."
  }
  assert {
    condition     = aws_scheduler_schedule.horario["db_encender"].schedule_expression == "cron(0 7 ? * MON-FRI *)"
    error_message = "La base debe encenderse a las 07:00 de lunes a viernes."
  }
  assert {
    condition     = aws_scheduler_schedule.horario["db_apagar"].schedule_expression_timezone == "America/Santiago"
    error_message = "El horario debe estar en hora de Chile."
  }
  assert {
    condition     = length(aws_budgets_budget.mensual) == 0
    error_message = "Sin correo de alertas no se crea el presupuesto."
  }
}

run "fines_de_semana" {
  command = apply
  variables {
    horario = "fines_de_semana"
  }

  assert {
    condition     = aws_scheduler_schedule.horario["db_apagar"].schedule_expression == "cron(0 23 ? * SUN *)"
    error_message = "La base debe apagarse el domingo a las 23:00."
  }
  assert {
    condition     = jsondecode(aws_scheduler_schedule.horario["db_encender"].target[0].input).DbInstanceIdentifier == aws_db_instance.principal.identifier
    error_message = "El encendido debe apuntar a la base del piloto."
  }
}

run "dominio_propio_con_correo" {
  command = apply
  variables {
    dominio                    = "app.paritario.cl"
    certificado_cloudfront_arn = "arn:aws:acm:us-east-1:123456789012:certificate/simulado"
    dominio_correo             = "paritario.cl"
  }

  assert {
    condition     = contains(aws_cloudfront_distribution.principal.aliases, "app.paritario.cl")
    error_message = "El dominio propio debe quedar como alias de CloudFront."
  }
  assert {
    condition     = length(aws_sesv2_email_identity.dominio) == 1
    error_message = "Con dominio de correo se configura SES."
  }
  assert {
    condition     = output.url == "https://app.paritario.cl"
    error_message = "La URL debe usar el dominio propio."
  }
}

run "tiempo_maximo_fuera_de_rango_es_rechazado" {
  command = plan
  variables {
    api_tiempo_max = 60
  }
  expect_failures = [var.api_tiempo_max]
}

run "dominio_sin_certificado_es_rechazado" {
  command = plan
  variables {
    dominio = "app.paritario.cl"
  }
  expect_failures = [aws_cloudfront_distribution.principal]
}

run "horario_invalido_es_rechazado" {
  command = plan
  variables {
    horario = "nunca"
  }
  expect_failures = [var.horario]
}
