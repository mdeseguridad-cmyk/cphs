# Red del piloto: dos subredes públicas (balanceador y tareas de la API) y dos
# privadas (base de datos), en dos zonas de disponibilidad. Sin NAT Gateway:
# las tareas de la API salen a internet con IP pública, y solo aceptan
# tráfico del balanceador. La base de datos no tiene salida a internet.

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
  map_public_ip_on_launch = false # las tareas reciben IP pública solo si su servicio la pide
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

# Las subredes privadas usan la tabla principal de la VPC, sin ruta a internet.

# Grupo por defecto de la VPC sin reglas: nada queda abierto por omisión.
resource "aws_default_security_group" "principal" {
  vpc_id = aws_vpc.principal.id
}

# --- Grupos de seguridad -------------------------------------------------

# Solo CloudFront puede llegar al balanceador.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${local.nombre}-alb"
  description = "Balanceador: solo acepta trafico de CloudFront"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_desde_cloudfront" {
  #checkov:skip=CKV_AWS_260:El origen es la lista de prefijos de CloudFront, no 0.0.0.0/0
  security_group_id = aws_security_group.alb.id
  description       = "Desde CloudFront"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = local.origen_https ? 443 : 80
  to_port           = local.origen_https ? 443 : 80
}

resource "aws_vpc_security_group_egress_rule" "alb_a_api" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Hacia las tareas de la API"
  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = var.api_puerto
  to_port                      = var.api_puerto
}

resource "aws_security_group" "api" {
  name        = "${local.nombre}-api"
  description = "Tareas de la API y de carga de la base"
  vpc_id      = aws_vpc.principal.id
}

resource "aws_vpc_security_group_ingress_rule" "api_desde_alb" {
  security_group_id            = aws_security_group.api.id
  description                  = "Solo desde el balanceador"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.api_puerto
  to_port                      = var.api_puerto
}

resource "aws_vpc_security_group_egress_rule" "api_https" {
  security_group_id = aws_security_group.api.id
  description       = "HTTPS hacia servicios de AWS (ECR, Secrets Manager, S3, SES, Cognito)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "api_a_db" {
  security_group_id            = aws_security_group.api.id
  description                  = "Hacia la base de datos"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_security_group" "db" {
  name        = "${local.nombre}-db"
  description = "Base de datos: solo desde las tareas de la API"
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
