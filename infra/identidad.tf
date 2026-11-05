# Inicio de sesión con Cognito. El nombre de usuario es el RUT (formato
# 12345678-5, como en la tabla usuario); el correo se usa para recuperar la
# cuenta. MFA con aplicación autenticadora, opcional en el piloto.

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
}

resource "aws_cognito_user_pool_client" "spa" {
  name                          = "${local.nombre}-spa"
  user_pool_id                  = aws_cognito_user_pool.principal.id
  generate_secret               = false # aplicación de página única: no puede guardar secretos
  explicit_auth_flows           = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
  access_token_validity         = 60
  id_token_validity             = 60
  refresh_token_validity        = 12
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }
}
