#!/usr/bin/env bash
# Da de alta una empresa cliente y su primer administrador, y envía la
# invitación de Cognito (correo con clave temporal). Desde ahí, ese
# administrador invita al resto desde la aplicación.
#
# Requisitos: aws CLI v2 y terraform, con credenciales de la cuenta del piloto,
# y la base ya cargada (scripts/cargar_base.sh).
#
# Uso:
#   infra/scripts/alta_empresa.sh \
#     --rut-empresa 76.123.456-7 --razon-social "Constructora Ejemplo S.A." \
#     [--actividad 410010] [--organismo-administrador ACHS|IST|MUSEG|ISL] \
#     --rut-admin 12.345.678-5 --nombres "María" --apellidos "Paredes" \
#     --correo maria@empresa.cl
set -euo pipefail

INFRA=$(cd "$(dirname "$0")/.." && pwd)
source "$INFRA/scripts/lib/tarea_base.sh"

uso() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

RUT_EMPRESA="" RAZON="" ACTIVIDAD="" OA="" RUT_ADMIN="" NOMBRES="" APELLIDOS="" CORREO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rut-empresa) RUT_EMPRESA=$2 ;;
    --razon-social) RAZON=$2 ;;
    --actividad) ACTIVIDAD=$2 ;;
    --organismo-administrador) OA=$2 ;;
    --rut-admin) RUT_ADMIN=$2 ;;
    --nombres) NOMBRES=$2 ;;
    --apellidos) APELLIDOS=$2 ;;
    --correo) CORREO=$2 ;;
    *) uso ;;
  esac
  shift 2
done
[ -n "$RUT_EMPRESA" ] && [ -n "$RAZON" ] && [ -n "$RUT_ADMIN" ] && [ -n "$NOMBRES" ] && [ -n "$APELLIDOS" ] && [ -n "$CORREO" ] || uso

# RUT sin puntos, con guion y K mayúscula; con dígito verificador válido.
normalizar() { echo "$1" | tr -d '. ' | tr 'k' 'K'; }
rut_valido() {
  local rut=$1 cuerpo dv suma=0 mult=2 i esperado
  [[ $rut =~ ^([0-9]{6,8})-([0-9K])$ ]] || return 1
  cuerpo=${BASH_REMATCH[1]} dv=${BASH_REMATCH[2]}
  for ((i = ${#cuerpo} - 1; i >= 0; i--)); do
    suma=$((suma + ${cuerpo:i:1} * mult))
    mult=$((mult == 7 ? 2 : mult + 1))
  done
  esperado=$((11 - suma % 11))
  case $esperado in 11) esperado=0 ;; 10) esperado=K ;; esac
  [ "$dv" = "$esperado" ]
}
RUT_EMPRESA=$(normalizar "$RUT_EMPRESA")
RUT_ADMIN=$(normalizar "$RUT_ADMIN")
rut_valido "$RUT_EMPRESA" || { echo "RUT de empresa inválido: $RUT_EMPRESA" >&2; exit 1; }
rut_valido "$RUT_ADMIN" || { echo "RUT del administrador inválido: $RUT_ADMIN" >&2; exit 1; }
[[ $CORREO =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "Correo inválido: $CORREO" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/carga"
cp "$INFRA/scripts/alta/alta.sh" "$TMP/carga/cargar.sh"

ejecutar_en_base "$TMP" alta-empresa \
  "ALTA_RUT_EMPRESA=$RUT_EMPRESA" "ALTA_RAZON_SOCIAL=$RAZON" "ALTA_ACTIVIDAD=$ACTIVIDAD" \
  "ALTA_ORGANISMO_ADMINISTRADOR=$OA" "ALTA_RUT_ADMIN=$RUT_ADMIN" "ALTA_NOMBRES=$NOMBRES" \
  "ALTA_APELLIDOS=$APELLIDOS" "ALTA_CORREO=$CORREO"

# La cuenta de Cognito: usuario = RUT; Cognito envía el correo con la clave temporal.
POOL=$(salida cognito_user_pool_id)
if aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$RUT_ADMIN" >/dev/null 2>&1; then
  echo "La cuenta $RUT_ADMIN ya existe en Cognito: no se reenvía la invitación."
else
  aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$RUT_ADMIN" \
    --user-attributes Name=email,Value="$CORREO" Name=email_verified,Value=true \
    --desired-delivery-mediums EMAIL >/dev/null
  echo "Invitación enviada a $CORREO. Entrará en $(salida url) con su RUT y la clave temporal."
fi
