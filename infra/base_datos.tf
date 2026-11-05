# PostgreSQL 16 en RDS, en subredes privadas, cifrado y con TLS obligatorio.
# La clave del usuario administrador la genera y guarda RDS en Secrets Manager.
# La aplicación usa otro usuario (paritario_app), sin privilegios de dueño,
# para que la seguridad por fila se aplique siempre (ver db/schema.sql).

resource "aws_db_subnet_group" "principal" {
  name       = local.nombre
  subnet_ids = aws_subnet.privada[*].id
}

resource "aws_db_parameter_group" "principal" {
  name   = "${local.nombre}-pg16"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # registra consultas de más de 1 segundo
  }
}

resource "aws_db_instance" "principal" {
  #checkov:skip=CKV_AWS_157:Multi-AZ configurable (var.db_multi_az); apagado en el piloto por costo
  #checkov:skip=CKV_AWS_118:Monitoreo mejorado recomendado para producción
  #checkov:skip=CKV_AWS_353:Performance Insights recomendado para producción
  identifier     = local.nombre
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_clase

  allocated_storage     = var.db_almacenamiento_gb
  max_allocated_storage = var.db_almacenamiento_gb * 5
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name                     = "paritario"
  username                    = "paritario_admin"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.principal.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.principal.name
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period             = 7
  backup_window                       = "06:00-07:00"         # UTC: madrugada en Chile
  maintenance_window                  = "sun:08:00-sun:09:00" # sin superponerse con el respaldo
  auto_minor_version_upgrade          = true
  copy_tags_to_snapshot               = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  iam_database_authentication_enabled = true

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.nombre}-final"
}

# Credenciales del usuario de la aplicación. scripts/cargar_base.sh crea el
# rol en PostgreSQL con esta clave.
resource "random_password" "db_app" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db_app" {
  #checkov:skip=CKV2_AWS_57:Rotación recomendada para producción (requiere una función Lambda de rotación)
  #checkov:skip=CKV_AWS_149:Cifrado con la llave administrada por AWS; llave propia recomendada para producción
  name                    = "${local.nombre}/db-app"
  description             = "Usuario de la aplicación en PostgreSQL (sujeto a seguridad por fila)"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db_app" {
  secret_id = aws_secretsmanager_secret.db_app.id
  secret_string = jsonencode({
    username = "paritario_app"
    password = random_password.db_app.result
    host     = aws_db_instance.principal.address
    port     = aws_db_instance.principal.port
    dbname   = aws_db_instance.principal.db_name
  })
}
