# CloudFront: único punto de entrada, con HTTPS.
#   /api/*  → función Lambda de la API, por su URL firmada (sin caché).
#             Solo existe cuando hay imagen de la API (var.api_imagen).
#   resto   → SPA en S3 (con caché); las rutas sin extensión devuelven
#             index.html para que funcione la navegación de la SPA.

resource "aws_cloudfront_origin_access_control" "front" {
  name                              = "${local.nombre}-front"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Reescribe /comites/123 a /index.html, sin tocar los archivos con extensión.
# Se hace con una función y no con páginas de error, para no reemplazar los
# errores de la API por index.html.
resource "aws_cloudfront_function" "spa" {
  name    = "${local.nombre}-spa"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-JS
    function handler(event) {
      var req = event.request;
      if (req.uri.indexOf('.') === -1) { req.uri = '/index.html'; }
      return req;
    }
  JS
}

# CloudFront firma cada solicitud a la función (SigV4). Por eso:
#   - pisa el encabezado Authorization: el front envía el token de Cognito en
#     X-Token-Usuario;
#   - en POST/PUT/PATCH el front debe enviar el SHA-256 del cuerpo en
#     x-amz-content-sha256.
resource "aws_cloudfront_origin_access_control" "api" {
  name                              = "${local.nombre}-api"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "optimizada" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "sin_cache" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "todo_menos_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_response_headers_policy" "seguridad" {
  name = "${local.nombre}-seguridad"
  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

resource "aws_cloudfront_distribution" "principal" {
  #checkov:skip=CKV2_AWS_42:El certificado propio es opcional (var.dominio); sin dominio se usa el de CloudFront
  #checkov:skip=CKV_AWS_174:Con el certificado por defecto de CloudFront no se puede fijar la versión mínima; con dominio propio se usa TLSv1.2_2021
  #checkov:skip=CKV_AWS_68:WAF recomendado para producción (~10-15 USD/mes); ver README, "Endurecimiento para producción"
  #checkov:skip=CKV2_AWS_47:WAF recomendado para producción; ver README
  #checkov:skip=CKV_AWS_86:Registros de acceso recomendados para producción; ver README
  #checkov:skip=CKV_AWS_310:Un solo origen por ruta; la conmutación por falla no aplica en el piloto
  #checkov:skip=CKV_AWS_374:Sin restricción geográfica: puede haber usuarios fuera de Chile
  enabled             = true
  comment             = local.nombre
  default_root_object = "index.html"
  price_class         = "PriceClass_All" # incluye los puntos de presencia de Sudamérica
  http_version        = "http2and3"
  aliases             = var.dominio != "" ? [var.dominio] : []

  origin {
    origin_id                = "front"
    domain_name              = aws_s3_bucket.b["front"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.front.id
  }

  dynamic "origin" {
    for_each = aws_lambda_function_url.api
    content {
      origin_id                = "api"
      domain_name              = split("/", origin.value.function_url)[2]
      origin_access_control_id = aws_cloudfront_origin_access_control.api.id
      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
        origin_read_timeout    = 30
      }
    }
  }

  default_cache_behavior {
    target_origin_id           = "front"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimizada.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.seguridad.id
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa.arn
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = aws_lambda_function_url.api
    content {
      path_pattern               = "/api/*"
      target_origin_id           = "api"
      viewer_protocol_policy     = "https-only"
      allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods             = ["GET", "HEAD"]
      compress                   = true
      cache_policy_id            = data.aws_cloudfront_cache_policy.sin_cache.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.todo_menos_host.id
      response_headers_policy_id = aws_cloudfront_response_headers_policy.seguridad.id
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.dominio == ""
    acm_certificate_arn            = var.dominio != "" ? var.certificado_cloudfront_arn : null
    ssl_support_method             = var.dominio != "" ? "sni-only" : null
    minimum_protocol_version       = var.dominio != "" ? "TLSv1.2_2021" : "TLSv1"
  }

  lifecycle {
    precondition {
      condition     = var.dominio == "" || var.certificado_cloudfront_arn != ""
      error_message = "Si define dominio, debe indicar certificado_cloudfront_arn (certificado de ACM en us-east-1)."
    }
  }
}
