# Red del piloto, en dos zonas de disponibilidad y sin NAT Gateway:
#   subredes privadas  base de datos y función de la API (Lambda). Sin salida
#                      a internet; S3 se alcanza por un endpoint de tipo
#                      gateway, que no tiene costo.
#   subredes públicas  solo la tarea de carga de la base, que se ejecuta a
#                      mano y necesita internet para bajar su imagen.

resource "aws_vpc" "principal" {
  #checkov:skip=CKV2_AWS_11:Registros de flujo de la VPC recomendados para producción
  cidr_block           = var.cidr_vpc
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.nombre }
}

resource "aws_internet_gateway" "principal" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = local.nombre }
}

resource "aws_subnet" "publica" {
  count                   = 2
  vpc_id                  = aws_vpc.principal.id
  cidr_block              = cidrsubnet(var.cidr_vpc, 8, count.index)
  availability_zone       = data.aws_availability_zones.disponibles.names[count.index]
  map_public_ip_on_launch = false # la tarea de carga pide su IP pública al lanzarse
  tags                    = { Name = "${local.nombre}-publica-${count.index + 1}" }
}

resource "aws_subnet" "privada" {
  count                   = 2
  vpc_id                  = aws_vpc.principal.id
  cidr_block              = cidrsubnet(var.cidr_vpc, 8, count.index + 10)
  availability_zone       = data.aws_availability_zones.disponibles.names[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.nombre}-privada-${count.index + 1}" }
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.principal.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.principal.id
  }
  tags = { Name = "${local.nombre}-publica" }
}

resource "aws_route_table_association" "publica" {
  count          = 2
  subnet_id      = aws_subnet.publica[count.index].id
  route_table_id = aws_route_table.publica.id
}

# Tabla de las subredes privadas: sin ruta a internet, solo el endpoint de S3.
resource "aws_route_table" "privada" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = "${local.nombre}-privada" }
}

resource "aws_route_table_association" "privada" {
  count          = 2
  subnet_id      = aws_subnet.privada[count.index].id
  route_table_id = aws_route_table.privada.id
}

# Endpoint de S3 (gratuito). Su política limita el acceso desde la red privada
# a los buckets del piloto: aunque el código fallara, no podría sacar datos a
# otro bucket.
data "aws_iam_policy_document" "endpoint_s3" {
  statement {
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = flatten([
      for k in ["documentos", "operaciones"] : [aws_s3_bucket.b[k].arn, "${aws_s3_bucket.b[k].arn}/*"]
    ])
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.principal.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.privada.id]
  policy            = data.aws_iam_policy_document.endpoint_s3.json
  tags              = { Name = "${local.nombre}-s3" }
}

# Grupo por defecto de la VPC sin reglas: nada queda abierto por omisión.
resource "aws_default_security_group" "principal" {
  vpc_id = aws_vpc.principal.id
}

# --- Grupos de seguridad -------------------------------------------------

# Función de la API: no recibe conexiones (Lambda no las necesita); solo sale
# hacia la base y hacia S3.
resource "aws_security_group" "api" {
  name        = "${local.nombre}-api"
  description = "Funcion de la API: sale solo hacia la base y S3"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_vpc_security_group_egress_rule" "api_a_db" {
  security_group_id            = aws_security_group.api.id
  description                  = "Hacia la base de datos"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "api_a_s3" {
  security_group_id = aws_security_group.api.id
  description       = "Hacia S3 por el endpoint"
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# Tarea de carga de la base: baja su imagen y el paquete de carga por HTTPS.
resource "aws_security_group" "carga" {
  #checkov:skip=CKV2_AWS_5:Se asigna al lanzar la tarea de carga (scripts/cargar_base.sh)
  name        = "${local.nombre}-carga"
  description = "Tarea de carga de la base: sin entradas"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_vpc_security_group_egress_rule" "carga_https" {
  security_group_id = aws_security_group.carga.id
  description       = "HTTPS para bajar la imagen y el paquete de carga"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "carga_a_db" {
  security_group_id            = aws_security_group.carga.id
  description                  = "Hacia la base de datos"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_security_group" "db" {
  name        = "${local.nombre}-db"
  description = "Base de datos: solo desde la API y la tarea de carga"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_vpc_security_group_ingress_rule" "db_desde_api" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL desde la API"
  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "db_desde_carga" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL desde la tarea de carga"
  referenced_security_group_id = aws_security_group.carga.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
