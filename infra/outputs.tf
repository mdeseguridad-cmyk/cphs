output "url" {
  description = "Dirección del sitio."
  value       = var.dominio != "" ? "https://${var.dominio}" : "https://${aws_cloudfront_distribution.principal.domain_name}"
}

output "cloudfront_dominio" {
  description = "Dominio de CloudFront; si usa dominio propio, apunte su registro CNAME aquí."
  value       = aws_cloudfront_distribution.principal.domain_name
}

output "cloudfront_id" {
  description = "Id de la distribución (para invalidar la caché al publicar el front)."
  value       = aws_cloudfront_distribution.principal.id
}

output "ecr_repositorio" {
  description = "Repositorio donde se publica la imagen de la API (arquitectura ARM64)."
  value       = aws_ecr_repository.api.repository_url
}

output "bucket_front" {
  value = aws_s3_bucket.b["front"].bucket
}

output "bucket_documentos" {
  value = aws_s3_bucket.b["documentos"].bucket
}

output "bucket_operaciones" {
  value = aws_s3_bucket.b["operaciones"].bucket
}

output "db_direccion" {
  value = aws_db_instance.principal.address
}

output "db_secreto_admin_arn" {
  description = "Secreto con la clave del administrador de la base (lo gestiona RDS)."
  value       = local.db_admin_arn
}

output "db_secreto_app_arn" {
  description = "Secreto con las credenciales del usuario de la aplicación."
  value       = aws_secretsmanager_secret.db_app.arn
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.principal.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.spa.id
}

output "ecs_cluster" {
  value = aws_ecs_cluster.principal.name
}

output "carga_tarea" {
  description = "Definición de tarea para la carga inicial de la base."
  value       = aws_ecs_task_definition.carga.family
}

output "subredes_publicas" {
  value = aws_subnet.publica[*].id
}

output "grupo_seguridad_api" {
  value = aws_security_group.api.id
}

output "dkim_registros" {
  description = "Registros CNAME que hay que publicar en el DNS del dominio de correo."
  value = var.dominio_correo != "" ? [
    for t in try(aws_sesv2_email_identity.dominio[0].dkim_signing_attributes[0].tokens, []) :
    { nombre = "${t}._domainkey.${var.dominio_correo}", tipo = "CNAME", valor = "${t}.dkim.amazonses.com" }
  ] : []
}
