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
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:sa-east-1:123456789012:secret:rds-admin", kms_key_id = "k", secret_status = "active" }]
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::bucket-simulado" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:sa-east-1:123456789012:secret:app" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/simulado" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:sa-east-1:123456789012:task-definition/simulada:1" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/simulado/1" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = { arn = "arn:aws:cloudfront::123456789012:distribution/SIMULADA" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:loadbalancer/app/simulado/1", dns_name = "simulado.sa-east-1.elb.amazonaws.com" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener/app/simulado/1/1" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:sa-east-1:123456789012:cluster/paritario-piloto", id = "arn:aws:ecs:sa-east-1:123456789012:cluster/paritario-piloto" }
  }
  mock_resource "aws_ecs_service" {
    defaults = { id = "arn:aws:ecs:sa-east-1:123456789012:service/paritario-piloto/api" }
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
  mock_resource "aws_cloudfront_function" {
    defaults = { arn = "arn:aws:cloudfront::123456789012:function/simulada" }
  }
}

mock_provider "random" {}

run "piloto_sin_aplicacion" {
  command = apply
  variables {
    correo_alertas = "alertas@ejemplo.cl"
  }

  assert {
    condition     = aws_ecs_service.api.desired_count == 0
    error_message = "Sin imagen de la API, el servicio debe quedar con 0 tareas."
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
    condition     = aws_db_instance.principal.deletion_protection
    error_message = "La base debe tener protección contra borrado."
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
}

run "con_aplicacion_y_dias_habiles" {
  command = apply
  variables {
    api_imagen = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/paritario-piloto-api:1.0.0"
    api_tareas = 2
    horario    = "dias_habiles"
  }

  assert {
    condition     = aws_ecs_service.api.desired_count == 2
    error_message = "Con imagen, el servicio debe tener las tareas pedidas."
  }
  assert {
    condition     = length(aws_scheduler_schedule.horario) == 4
    error_message = "El horario de días hábiles debe crear 4 programaciones."
  }
  assert {
    condition     = aws_scheduler_schedule.horario["db_encender"].schedule_expression == "cron(0 7 ? * MON-FRI *)"
    error_message = "La base debe encenderse a las 07:00 de lunes a viernes."
  }
  assert {
    condition     = jsondecode(aws_scheduler_schedule.horario["api_encender"].target[0].input).DesiredCount == 2
    error_message = "El encendido debe restaurar las tareas pedidas."
  }
  assert {
    condition     = aws_scheduler_schedule.horario["api_apagar"].schedule_expression_timezone == "America/Santiago"
    error_message = "El horario debe estar en hora de Chile."
  }
  assert {
    condition     = length(aws_budgets_budget.mensual) == 0
    error_message = "Sin correo de alertas no se crea el presupuesto."
  }
}

run "fines_de_semana_sin_aplicacion_no_enciende_tareas" {
  command = apply
  variables {
    horario = "fines_de_semana"
  }

  assert {
    condition     = jsondecode(aws_scheduler_schedule.horario["api_encender"].target[0].input).DesiredCount == 0
    error_message = "Sin imagen, el encendido programado no debe levantar tareas."
  }
  assert {
    condition     = aws_scheduler_schedule.horario["db_apagar"].schedule_expression == "cron(15 23 ? * SUN *)"
    error_message = "La base debe apagarse el domingo a las 23:15."
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

run "origen_cifrado_con_certificado" {
  command = apply
  variables {
    dominio_origen      = "origen.app.paritario.cl"
    certificado_alb_arn = "arn:aws:acm:sa-east-1:123456789012:certificate/simulado"
  }

  assert {
    condition     = length(aws_lb_listener.http) == 0 && length(aws_lb_listener.https) == 1
    error_message = "Con certificado de origen solo debe existir el listener HTTPS."
  }
  assert {
    condition     = one([for o in aws_cloudfront_distribution.principal.origin : o.custom_origin_config[0].origin_protocol_policy if o.origin_id == "api"]) == "https-only"
    error_message = "CloudFront debe llegar al balanceador por HTTPS."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_desde_cloudfront.from_port == 443
    error_message = "El balanceador debe admitir CloudFront en el puerto 443."
  }
}

run "origen_sin_certificado_es_rechazado" {
  command = plan
  variables {
    dominio_origen = "origen.app.paritario.cl"
  }
  expect_failures = [aws_cloudfront_distribution.principal]
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
