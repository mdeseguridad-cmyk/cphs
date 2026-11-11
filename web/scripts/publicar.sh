#!/usr/bin/env bash
# Compila la aplicación web y la publica en el bucket del front, con su
# config.json generado desde las salidas de Terraform (infra/).
#
# Requisitos: Node 22, AWS CLI v2 y terraform, con credenciales de la cuenta.
# Uso: web/scripts/publicar.sh
#
# Etiquetas de los botones de inicio de sesión de clientes (opcional), como
# JSON {"nombre-del-proveedor": "Texto del botón"}:
#   ETIQUETAS='{"mutual-a": "Mutualidad Ejemplo"}' web/scripts/publicar.sh
set -euo pipefail

WEB=$(cd "$(dirname "$0")/.." && pwd)
INFRA="$WEB/../infra"
salida() { terraform -chdir="$INFRA" output -raw "$1"; }

npm --prefix "$WEB" ci --no-audit --no-fund
npm --prefix "$WEB" run build

BUCKET=$(salida bucket_front)
DISTRIBUCION=$(salida cloudfront_id)

CONFIG=$(
  POOL=$(salida cognito_user_pool_id) CLIENTE=$(salida cognito_client_id) REGION=$(salida region) \
  DOMINIO=$(salida cognito_dominio) PROVEEDORES=$(terraform -chdir="$INFRA" output -json proveedores_identidad) \
  ETIQUETAS=${ETIQUETAS:-"{}"} \
  node -e '
    const e = process.env, etiquetas = JSON.parse(e.ETIQUETAS);
    console.log(JSON.stringify({
      auth: "cognito",
      entorno: "piloto",
      region: e.REGION,
      userPoolId: e.POOL,
      clientId: e.CLIENTE,
      cognitoDominio: e.DOMINIO,
      proveedores: JSON.parse(e.PROVEEDORES).map((n) => ({ nombre: n, etiqueta: etiquetas[n] ?? n })),
    }, null, 2));'
)
echo "$CONFIG" > "$WEB/dist/config.json"

# Archivos con huella en el nombre: caché larga. index.html y config.json: siempre frescos.
# Los mapas de código fuente no se publican.
aws s3 sync "$WEB/dist/assets" "s3://$BUCKET/assets" --delete --exclude "*.map" \
  --cache-control "public, max-age=31536000, immutable"
for f in index.html config.json; do
  aws s3 cp "$WEB/dist/$f" "s3://$BUCKET/$f" --cache-control "no-cache, max-age=0"
done
# MSYS_NO_PATHCONV: en Git Bash (Windows), evita que "/index.html" se convierta en una ruta de Windows.
MSYS_NO_PATHCONV=1 aws cloudfront create-invalidation --distribution-id "$DISTRIBUCION" --paths "/index.html" "/config.json" "/" >/dev/null

echo "Publicado en $(salida url)"
