# API en contenedores (ECS Fargate) detrás de un balanceador al que solo
# CloudFront puede llegar. Mientras no exista la imagen de la aplicación
# (var.api_imagen vacía), el servicio queda creado con 0 tareas.

locals {
  api_imagen   = var.api_imagen != "" ? var.api_imagen : "${aws_ecr_repository.api.repository_url}:latest"
  api_tareas   = var.api_imagen != "" ? var.api_tareas : 0
  db_admin_arn = aws_db_instance.principal.master_user_secret[0].secret_arn
  origen_https = var.certificado_alb_arn != ""
  listener_arn = local.origen_https ? aws_lb_listener.https[0].arn : aws_lb_listener.http[0].arn
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

resource "aws_ecs_cluster" "principal" {
  #checkov:skip=CKV_AWS_65:Container Insights recomendado para producción; agrega costo
  name = local.nombre
  setting {
    name  = "containerInsights"
    value = "disabled" # se activa en producción; en el piloto agrega costo
  }
}

resource "aws_cloudwatch_log_group" "api" {
  #checkov:skip=CKV_AWS_338:30 días por minimización de datos personales (Ley 21.719)
  #checkov:skip=CKV_AWS_158:Cifrado por defecto de CloudWatch; llave propia recomendada para producción
  name              = "/ecs/${local.nombre}/api"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "carga" {
  #checkov:skip=CKV_AWS_338:30 días: registros de una tarea de operación
  #checkov:skip=CKV_AWS_158:Cifrado por defecto de CloudWatch
  name              = "/ecs/${local.nombre}/carga-base"
  retention_in_days = 30
}

# --- Roles ---------------------------------------------------------------

data "aws_iam_policy_document" "asumir_ecs" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Rol de ejecución: lo usa ECS para bajar la imagen, escribir logs y leer
# los secretos que se inyectan como variables de entorno.
resource "aws_iam_role" "ejecucion" {
  name               = "${local.nombre}-ecs-ejecucion"
  assume_role_policy = data.aws_iam_policy_document.asumir_ecs.json
}

resource "aws_iam_role_policy_attachment" "ejecucion" {
  role       = aws_iam_role.ejecucion.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ejecucion_secretos" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db_app.arn, local.db_admin_arn]
  }
}

resource "aws_iam_role_policy" "ejecucion_secretos" {
  name   = "leer-secretos"
  role   = aws_iam_role.ejecucion.id
  policy = data.aws_iam_policy_document.ejecucion_secretos.json
}

# Rol de la API: documentos en S3 y envío de correos. Nada más.
resource "aws_iam_role" "api" {
  name               = "${local.nombre}-api"
  assume_role_policy = data.aws_iam_policy_document.asumir_ecs.json
}

data "aws_iam_policy_document" "api" {
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
    sid       = "Correo"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = [var.dominio_correo != "" ? "*@${var.dominio_correo}" : "*"]
    }
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "api"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

# --- Tarea y servicio de la API -------------------------------------------

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.nombre}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memoria
  execution_role_arn       = aws_iam_role.ejecucion.arn
  task_role_arn            = aws_iam_role.api.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # Graviton: ~20 % más barato
  }

  container_definitions = jsonencode([{
    name                   = "api"
    image                  = local.api_imagen
    essential              = true
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = var.api_puerto, protocol = "tcp" }]
    environment = [
      { name = "PUERTO", value = tostring(var.api_puerto) },
      { name = "AWS_REGION", value = var.region },
      { name = "DB_HOST", value = aws_db_instance.principal.address },
      { name = "DB_PORT", value = tostring(aws_db_instance.principal.port) },
      { name = "DB_NAME", value = aws_db_instance.principal.db_name },
      { name = "DB_USER", value = "paritario_app" },
      { name = "DB_SSLMODE", value = "require" },
      { name = "DOCUMENTOS_BUCKET", value = aws_s3_bucket.b["documentos"].bucket },
      { name = "COGNITO_USER_POOL_ID", value = aws_cognito_user_pool.principal.id },
      { name = "COGNITO_CLIENT_ID", value = aws_cognito_user_pool_client.spa.id },
      { name = "CORREO_REMITENTE", value = var.dominio_correo != "" ? "notificaciones@${var.dominio_correo}" : "" },
    ]
    secrets = [
      { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db_app.arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "api"
      }
    }
  }])
}

resource "aws_ecs_service" "api" {
  #checkov:skip=CKV_AWS_333:Piloto sin NAT Gateway (ahorra ~35 USD/mes); el grupo de seguridad solo admite tráfico del balanceador
  name            = "api"
  cluster         = aws_ecs_cluster.principal.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = local.api_tareas
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.publica[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true # sin NAT Gateway; el grupo de seguridad solo admite al balanceador
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = var.api_puerto
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 60

  # Con horario de encendido (horario.tf), un apply fuera de horario deja la
  # API encendida hasta el siguiente apagado programado.

  depends_on = [aws_lb_listener.http, aws_lb_listener.https]
}

# --- Tarea de carga inicial de la base (scripts/cargar_base.sh) -----------

resource "aws_ecs_task_definition" "carga" {
  family                   = "${local.nombre}-carga-base"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ejecucion.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "carga"
    image     = "public.ecr.aws/docker/library/postgres:16-alpine"
    essential = true
    command   = ["sh", "-c", "wget -qO- \"$URL_CARGA\" | tar xz -C /tmp && sh /tmp/carga/cargar.sh"]
    environment = [
      { name = "PGHOST", value = aws_db_instance.principal.address },
      { name = "PGPORT", value = tostring(aws_db_instance.principal.port) },
      { name = "PGDATABASE", value = aws_db_instance.principal.db_name },
      { name = "PGUSER", value = aws_db_instance.principal.username },
      { name = "PGSSLMODE", value = "require" },
    ]
    secrets = [
      { name = "PGPASSWORD", valueFrom = "${local.db_admin_arn}:password::" },
      { name = "APP_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db_app.arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.carga.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "carga"
      }
    }
  }])
}

# --- Balanceador -----------------------------------------------------------

# CloudFront agrega este encabezado; sin él, el balanceador responde 403.
resource "random_password" "encabezado_origen" {
  length  = 40
  special = false
}

resource "aws_lb" "api" {
  #checkov:skip=CKV2_AWS_28:Público solo para la lista de prefijos de CloudFront; WAF recomendado para producción en CloudFront
  #checkov:skip=CKV_AWS_91:Registros de acceso recomendados para producción
  #checkov:skip=CKV2_AWS_20:El listener HTTP solo existe sin certificado de origen (datos de prueba)
  name                       = local.nombre
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.publica[*].id
  drop_invalid_header_fields = true
  enable_deletion_protection = true
}

resource "aws_lb_target_group" "api" {
  #checkov:skip=CKV_AWS_378:Balanceador→tareas dentro de la VPC, entre grupos de seguridad que solo se admiten entre sí
  name                 = "${local.nombre}-api"
  port                 = var.api_puerto
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.principal.id
  deregistration_delay = 30
  health_check {
    path                = var.api_ruta_salud
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Sin dominio_origen, CloudFront llega al balanceador por HTTP: el tramo no va
# cifrado. Aceptable solo con datos de prueba; antes de cargar datos reales,
# defina dominio_origen y certificado_alb_arn (ver README.md).
resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:Solo existe sin certificado de origen; con datos reales se usa el listener HTTPS
  #checkov:skip=CKV2_AWS_20:Solo existe sin certificado de origen; con datos reales se usa el listener HTTPS
  #checkov:skip=CKV_AWS_103:Solo existe sin certificado de origen; con datos reales se usa el listener HTTPS
  count             = local.origen_https ? 0 : 1
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Acceso denegado"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = local.origen_https ? 1 : 0
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificado_alb_arn
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Acceso denegado"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "desde_cloudfront" {
  listener_arn = local.listener_arn
  priority     = 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
  condition {
    http_header {
      http_header_name = "X-Origen-Verificado"
      values           = [random_password.encabezado_origen.result]
    }
  }
}
