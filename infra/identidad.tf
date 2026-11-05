# Inicio de sesión con Cognito. El nombre de usuario es el RUT (formato
# 12345678-5, como en la tabla usuario); el correo se usa para recuperar la
# cuenta. MFA con aplicación autenticadora, opcional en el piloto.
#
# Un cliente u organismo puede conectar su propio inicio de sesión (SAML u
# OIDC, var.proveedores_identidad). Su sistema envía el RUT, el rol y los
# contratos del usuario en atributos propios (custom:rut, custom:rol_externo,
# custom:contratos); en cada ingreso la API concilia los accesos con
# sincronizar_accesos_sso() en la base.

locals {
  federado = nonsensitive(length(var.proveedores_identidad) > 0) # si hay proveedores no es secreto; sus datos sí
}

resource "aws_cognito_user_pool" "principal" {
  name                     = local.nombre
  deletion_protection      = "ACTIVE"
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 10
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = true # el alta la aprueba el administrador (solicitud_acceso)
  }

  username_configuration {
    case_sensitive = false
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 160
    }
  }

  # Atributos que llegan del inicio de sesión de un cliente. Se crean desde el
  # principio porque un user pool no admite cambiar su esquema después.
  schema {
    name                = "rut"
    attribute_data_type = "String"
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 12
    }
  }
  schema {
    name                = "rol_externo"
    attribute_data_type = "String"
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 100
    }
  }
  schema {
    name                = "contratos"
    attribute_data_type = "String"
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }
}

# Dominio de Cognito: necesario para la redirección del inicio de sesión
# federado. Solo existe si hay proveedores.
resource "aws_cognito_user_pool_domain" "principal" {
  count        = local.federado ? 1 : 0
  domain       = "${local.nombre}-${data.aws_caller_identity.actual.account_id}"
  user_pool_id = aws_cognito_user_pool.principal.id
}

resource "aws_cognito_identity_provider" "cliente" {
  for_each      = nonsensitive(toset(keys(var.proveedores_identidad)))
  user_pool_id  = aws_cognito_user_pool.principal.id
  provider_name = each.key
  provider_type = var.proveedores_identidad[each.key].tipo

  provider_details = var.proveedores_identidad[each.key].tipo == "SAML" ? {
    MetadataURL = var.proveedores_identidad[each.key].metadata_url
    } : {
    oidc_issuer               = var.proveedores_identidad[each.key].emisor
    client_id                 = var.proveedores_identidad[each.key].client_id
    client_secret             = var.proveedores_identidad[each.key].client_secret
    authorize_scopes          = "openid email profile"
    attributes_request_method = "GET"
  }

  attribute_mapping = { for k, v in {
    "custom:rut"         = var.proveedores_identidad[each.key].atributos.rut
    "custom:rol_externo" = var.proveedores_identidad[each.key].atributos.rol
    "custom:contratos"   = var.proveedores_identidad[each.key].atributos.contratos
    email                = var.proveedores_identidad[each.key].atributos.correo
  } : k => v if v != "" }

  lifecycle {
    precondition {
      condition     = var.dominio != ""
      error_message = "El inicio de sesión de un cliente requiere dominio propio (var.dominio): la dirección de retorno queda registrada en su sistema."
    }
  }
}

resource "aws_cognito_user_pool_client" "spa" {
  name                = "${local.nombre}-spa"
  user_pool_id        = aws_cognito_user_pool.principal.id
  generate_secret     = false # aplicación de página única: no puede guardar secretos
  explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]

  # Con proveedores de clientes, el front usa el flujo OAuth (código + PKCE)
  # para redirigir a su sistema. Sin ellos, solo usuario y contraseña.
  supported_identity_providers         = concat(["COGNITO"], [for p in aws_cognito_identity_provider.cliente : p.provider_name])
  allowed_oauth_flows_user_pool_client = local.federado
  allowed_oauth_flows                  = local.federado ? ["code"] : []
  allowed_oauth_scopes                 = local.federado ? ["openid", "email", "profile"] : []
  callback_urls                        = local.federado ? ["https://${var.dominio}/auth/callback"] : []
  logout_urls                          = local.federado ? ["https://${var.dominio}/"] : []
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  access_token_validity                = 60
  id_token_validity                    = 60
  refresh_token_validity               = 12
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }
}
