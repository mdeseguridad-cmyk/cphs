# Alertas de presupuesto: aviso al 33 % y al 100 % del gasto real del mes, y
# si el pronóstico del mes supera el presupuesto.

resource "aws_budgets_budget" "mensual" {
  count        = var.correo_alertas != "" ? 1 : 0
  name         = "${local.nombre}-mensual"
  budget_type  = "COST"
  limit_amount = tostring(var.presupuesto_mensual_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 33
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.correo_alertas]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.correo_alertas]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "FORECASTED"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.correo_alertas]
  }
}
