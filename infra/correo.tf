# Envío de correos con SES desde un dominio propio (opcional). Después del
# apply hay que publicar los registros DKIM (salida dkim_registros) en el DNS
# del dominio y pedir a AWS salir del modo sandbox (ver README.md).

resource "aws_sesv2_email_identity" "dominio" {
  count          = var.dominio_correo != "" ? 1 : 0
  email_identity = var.dominio_correo
}

resource "aws_sesv2_email_identity_mail_from_attributes" "dominio" {
  count                  = var.dominio_correo != "" ? 1 : 0
  email_identity         = aws_sesv2_email_identity.dominio[0].email_identity
  mail_from_domain       = "correo.${var.dominio_correo}"
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}
