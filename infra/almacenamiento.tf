# Tres buckets privados:
#   front        SPA estática; solo CloudFront la lee (Origin Access Control).
#   documentos   actas, informes y certificados; los lee y escribe la API.
#   operaciones  archivos temporales de operación (carga inicial de la base).

locals {
  buckets = {
    front       = "${local.nombre}-front-${data.aws_caller_identity.actual.account_id}"
    documentos  = "${local.nombre}-documentos-${data.aws_caller_identity.actual.account_id}"
    operaciones = "${local.nombre}-operaciones-${data.aws_caller_identity.actual.account_id}"
  }
}

resource "aws_s3_bucket" "b" {
  #checkov:skip=CKV2_AWS_6:El bloqueo de acceso público se aplica a los tres buckets con aws_s3_bucket_public_access_block.b (for_each)
  #checkov:skip=CKV_AWS_145:Cifrado SSE-S3; llaves propias (KMS) recomendadas para producción
  #checkov:skip=CKV_AWS_144:Sin replicación entre regiones en el piloto
  #checkov:skip=CKV_AWS_18:Registros de acceso recomendados para producción
  #checkov:skip=CKV2_AWS_62:No se usan notificaciones de eventos
  #checkov:skip=CKV_AWS_21:El versionado solo aplica a documentos; front y operaciones se regeneran
  #checkov:skip=CKV2_AWS_61:Los tres buckets tienen ciclo de vida (recursos aparte)
  for_each = local.buckets
  bucket   = each.value
}

resource "aws_s3_bucket_public_access_block" "b" {
  for_each                = aws_s3_bucket.b
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "b" {
  for_each = aws_s3_bucket.b
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "b" {
  for_each = aws_s3_bucket.b
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "documentos" {
  bucket = aws_s3_bucket.b["documentos"].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "operaciones" {
  bucket = aws_s3_bucket.b["operaciones"].id
  rule {
    id     = "borrar-temporales"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "front" {
  bucket = aws_s3_bucket.b["front"].id
  rule {
    id     = "cargas-incompletas"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "documentos" {
  bucket = aws_s3_bucket.b["documentos"].id
  rule {
    id     = "versiones-antiguas"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Políticas: solo conexiones cifradas; el bucket del front, además, solo lo
# lee esta distribución de CloudFront.
data "aws_iam_policy_document" "bucket" {
  for_each = aws_s3_bucket.b

  statement {
    sid     = "SoloTLS"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      each.value.arn,
      "${each.value.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = each.key == "front" ? [1] : []
    content {
      sid       = "LecturaDesdeCloudFront"
      actions   = ["s3:GetObject"]
      resources = ["${each.value.arn}/*"]
      principals {
        type        = "Service"
        identifiers = ["cloudfront.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "AWS:SourceArn"
        values   = [aws_cloudfront_distribution.principal.arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "b" {
  for_each   = aws_s3_bucket.b
  bucket     = each.value.id
  policy     = data.aws_iam_policy_document.bucket[each.key].json
  depends_on = [aws_s3_bucket_public_access_block.b]
}
