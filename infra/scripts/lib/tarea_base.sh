# Funciones compartidas para ejecutar algo en la base del piloto desde su
# computador. La base está en subredes privadas, así que el trabajo corre
# dentro de AWS como una tarea ECS de un solo uso (definición "carga-base",
# imagen postgres:16-alpine, con la clave del administrador de la base):
#
#   1. se empaqueta un directorio que contiene carga/cargar.sh,
#   2. se sube al bucket de operaciones (se borra solo a los 7 días),
#   3. se lanza la tarea con una URL firmada válida por 15 minutos,
#   4. se espera a que termine y se revisa su código de salida.
#
# Uso: source scripts/lib/tarea_base.sh; ejecutar_en_base DIR PREFIJO [VAR=valor ...]
#   DIR      directorio con carga/cargar.sh (y lo que ese script necesite)
#   PREFIJO  carpeta en el bucket de operaciones, p. ej. carga-base
#   VAR=…    variables de entorno adicionales para la tarea

INFRA=${INFRA:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
salida() { terraform -chdir="$INFRA" output -raw "$1"; }

encender_base() {
  local db estado
  db=$(salida db_direccion | cut -d. -f1)
  estado=$(aws rds describe-db-instances --db-instance-identifier "$db" \
    --query 'DBInstances[0].DBInstanceStatus' --output text)
  if [ "$estado" = "stopped" ]; then
    echo "La base está apagada (horario). Encendiéndola…"
    aws rds start-db-instance --db-instance-identifier "$db" >/dev/null
  fi
  if [ "$estado" != "available" ]; then
    echo "Esperando a que la base esté disponible (puede tardar unos 10 minutos)…"
    aws rds wait db-instance-available --db-instance-identifier "$db"
  fi
}

# JSON de una variable de entorno para containerOverrides, con el valor escapado.
_variable_json() {
  local nombre=${1%%=*} valor=${1#*=}
  valor=${valor//\\/\\\\}
  valor=${valor//\"/\\\"}
  printf '{"name":"%s","value":"%s"}' "$nombre" "$valor"
}

ejecutar_en_base() {
  local dir=$1 prefijo=$2
  shift 2
  local cluster tarea bucket sg subredes paquete clave url entorno arn codigo razon v
  cluster=$(salida ecs_cluster)
  tarea=$(salida carga_tarea)
  bucket=$(salida bucket_operaciones)
  sg=$(salida grupo_seguridad_carga)
  subredes=$(terraform -chdir="$INFRA" output -json subredes_publicas | tr -d '[]" ')

  encender_base

  paquete=$(mktemp)
  tar czf "$paquete" -C "$dir" carga
  clave="$prefijo/$(date -u +%Y%m%dT%H%M%SZ).tgz"
  aws s3 cp --only-show-errors "$paquete" "s3://$bucket/$clave"
  rm -f "$paquete"
  url=$(aws s3 presign "s3://$bucket/$clave" --expires-in 900)

  entorno=$(_variable_json "URL_CARGA=$url")
  for v in "$@"; do entorno="$entorno,$(_variable_json "$v")"; done

  echo "Lanzando la tarea en la base…"
  arn=$(aws ecs run-task --cluster "$cluster" --task-definition "$tarea" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$subredes],securityGroups=[$sg],assignPublicIp=ENABLED}" \
    --overrides "{\"containerOverrides\":[{\"name\":\"carga\",\"environment\":[$entorno]}]}" \
    --query 'tasks[0].taskArn' --output text)
  echo "Tarea: $arn"
  aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$arn"

  codigo=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$arn" \
    --query 'tasks[0].containers[0].exitCode' --output text)
  # MSYS_NO_PATHCONV: en Git Bash (Windows), evita que "/ecs/…" se convierta en
  # una ruta de Windows antes de llegar a AWS.
  echo "Registros: MSYS_NO_PATHCONV=1 aws logs tail /ecs/$cluster/carga-base --since 1h"
  if [ "$codigo" != "0" ]; then
    razon=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$arn" \
      --query 'tasks[0].stoppedReason' --output text)
    echo "La tarea falló (código $codigo): $razon" >&2
    echo "Últimos registros de la tarea:" >&2
    MSYS_NO_PATHCONV=1 aws logs tail "/ecs/$cluster/carga-base" --since 1h \
      --log-stream-name-prefix "carga/carga/${arn##*/}" --format short 2>&1 | tail -n 40 >&2 || true
    return 1
  fi
}
