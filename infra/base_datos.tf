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

  # Sin los valores de las consultas en el registro: podrían ser datos
  # personales (un RUT, un nombre). Queda la consulta, no sus parámetros.
  parameter {
    name  = "log_parameter_max_length"
    value = "0"
  }

  parameter {
    name  = "log_parameter_max_length_on_error"
    value = "0"
  }
}

# Registro de PostgreSQL en CloudWatch, con 30 días como los demás. Si no se
# declara, RDS lo crea sin vencimiento. Se crea antes que la base para que
# RDS use este. En una base ya creada, impórtelo una vez antes de aplicar:
#   MSYS_NO_PATHCONV=1 terraform import aws_cloudwatch_log_group.base /aws/rds/instance/paritario-piloto/postgresql
resource "aws_cloudwatch_log_group" "base" {
  #checkov:skip=CKV_AWS_338:30 días por minimización de datos personales (Ley 21.719)
  #checkov:skip=CKV_AWS_158:Cifrado por defecto de CloudWatch; llave propia recomendada para producción
  name              = "/aws/rds/instance/${local.nombre}/postgresql"
  retention_in_days = 30
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

  depends_on = [aws_cloudwatch_log_group.base]
}

# Credenciales del usuario de la aplicación. scripts/cargar_base.sh crea el
# rol en PostgreSQL con esta clave.

# La API se conecta como paritario_app con un token de IAM (rds-db:connect),
# generado localmente por el SDK: no hay clave de aplicación que guardar.
