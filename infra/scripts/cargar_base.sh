#!/usr/bin/env bash
# Carga el esquema y los catálogos en la base del piloto, desde su computador.
#
# La base está en subredes privadas, así que la carga corre dentro de AWS como
# una tarea ECS de un solo uso. Este script:
#   1. empaqueta db/*.sql y scripts/carga/cargar.sh,
#   2. lo sube al bucket de operaciones (se borra solo a los 7 días),
#   3. lanza la tarea con una URL firmada válida por 15 minutos,
#   4. espera a que termine y muestra el resultado.
#
# Requisitos: aws CLI v2 y terraform, con credenciales de la cuenta del piloto,
# y haber ejecutado "terraform apply" en infra/.
# Uso: infra/scripts/cargar_base.sh
set -euo pipefail

INFRA=$(cd "$(dirname "$0")/.." && pwd)
RAIZ=$(cd "$INFRA/.." && pwd)
salida() { terraform -chdir="$INFRA" output -raw "$1"; }

CLUSTER=$(salida ecs_cluster)
TAREA=$(salida carga_tarea)
BUCKET=$(salida bucket_operaciones)
SG=$(salida grupo_seguridad_api)
SUBREDES=$(terraform -chdir="$INFRA" output -json subredes_publicas | tr -d '[]" ')
DB=$(salida db_direccion | cut -d. -f1)

estado=$(aws rds describe-db-instances --db-instance-identifier "$DB" \
  --query 'DBInstances[0].DBInstanceStatus' --output text)
if [ "$estado" = "stopped" ]; then
  echo "La base está apagada (horario). Encendiéndola…"
  aws rds start-db-instance --db-instance-identifier "$DB" >/dev/null
fi
if [ "$estado" != "available" ]; then
  echo "Esperando a que la base esté disponible…"
  aws rds wait db-instance-available --db-instance-identifier "$DB"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/carga/db"
cp "$RAIZ"/db/schema.sql "$RAIZ"/db/seed*.sql "$TMP/carga/db/"
cp "$INFRA/scripts/carga/cargar.sh" "$TMP/carga/"
tar czf "$TMP/carga.tgz" -C "$TMP" carga

CLAVE="carga-base/$(date -u +%Y%m%dT%H%M%SZ).tgz"
aws s3 cp --only-show-errors "$TMP/carga.tgz" "s3://$BUCKET/$CLAVE"
URL=$(aws s3 presign "s3://$BUCKET/$CLAVE" --expires-in 900)

ANULACION=$(printf '{"containerOverrides":[{"name":"carga","environment":[{"name":"URL_CARGA","value":"%s"}]}]}' "$URL")
RED="awsvpcConfiguration={subnets=[$SUBREDES],securityGroups=[$SG],assignPublicIp=ENABLED}"

echo "Lanzando la tarea de carga…"
ARN=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TAREA" \
  --launch-type FARGATE --network-configuration "$RED" \
  --overrides "$ANULACION" --query 'tasks[0].taskArn' --output text)
echo "Tarea: $ARN"
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$ARN"

CODIGO=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text)
GRUPO="/ecs/$(salida ecs_cluster)/carga-base"
echo "Registros: aws logs tail $GRUPO --since 1h"
if [ "$CODIGO" != "0" ]; then
  RAZON=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$ARN" \
    --query 'tasks[0].stoppedReason' --output text)
  echo "La carga falló (código $CODIGO): $RAZON" >&2
  exit 1
fi
echo "Carga terminada correctamente."
