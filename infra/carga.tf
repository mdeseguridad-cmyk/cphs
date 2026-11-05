# Tarea de un solo uso para cargar el esquema y los catálogos en la base
# (scripts/cargar_base.sh). El clúster de ECS no cobra nada mientras no se
# ejecuta la tarea.

locals {
  db_admin_arn = aws_db_instance.principal.master_user_secret[0].secret_arn
}

resource "aws_ecs_cluster" "principal" {
  #checkov:skip=CKV_AWS_65:Solo ejecuta la tarea de carga; Container Insights no aporta
  name = local.nombre
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_cloudwatch_log_group" "carga" {
  #checkov:skip=CKV_AWS_338:30 días: registros de una tarea de operación
  #checkov:skip=CKV_AWS_158:Cifrado por defecto de CloudWatch
  name              = "/ecs/${local.nombre}/carga-base"
  retention_in_days = 30
}

data "aws_iam_policy_document" "asumir_ecs" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Rol de ejecución: bajar la imagen, escribir registros y leer la clave del
# administrador de la base, que se entrega a la tarea como variable.
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
    resources = [local.db_admin_arn]
  }
}

resource "aws_iam_role_policy" "ejecucion_secretos" {
  name   = "leer-secretos"
  role   = aws_iam_role.ejecucion.id
  policy = data.aws_iam_policy_document.ejecucion_secretos.json
}

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
      { name = "APP_DB_USUARIO", value = local.db_usuario_app },
    ]
    secrets = [
      { name = "PGPASSWORD", valueFrom = "${local.db_admin_arn}:password::" },
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
