#!/usr/bin/env bash
# Construye la imagen de la API para Lambda (ARM64) y la sube al repositorio
# ECR del piloto. Usa las salidas de Terraform (infra/).
#
# Requisitos: Docker con buildx, AWS CLI v2 y terraform, con credenciales de
# la cuenta del piloto.
# Uso: api/scripts/publicar.sh [etiqueta]     (por defecto, el commit actual)
set -euo pipefail

API=$(cd "$(dirname "$0")/.." && pwd)
INFRA="$API/../infra"
salida() { terraform -chdir="$INFRA" output -raw "$1"; }

REPO=$(salida ecr_repositorio)
EMISOR=$(salida cognito_emisor)
REGION=$(aws configure get region || echo sa-east-1)
ETIQUETA=${1:-$(git -C "$API" rev-parse --short HEAD)}

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO%%/*}"

docker buildx build --platform linux/arm64 --provenance=false \
  --build-arg COGNITO_EMISOR="$EMISOR" --build-arg REGION="$REGION" \
  -t "$REPO:$ETIQUETA" --push "$API"

echo
echo "Imagen publicada: $REPO:$ETIQUETA"
echo "Póngala en infra/terraform.tfvars y aplique:"
echo "  api_imagen = \"$REPO:$ETIQUETA\""
