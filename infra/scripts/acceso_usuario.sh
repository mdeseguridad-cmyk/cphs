#!/usr/bin/env bash
# Muestra el acceso actual de una persona al piloto, sin secretos:
#   - su cuenta en Cognito: si existe, su estado y si está habilitada;
#   - en Paritario: su estado, último ingreso y roles por empresa o comité.
# Nunca muestra contraseñas (nadie puede leerlas) ni correos.
#
# Requisitos: aws CLI v2 y terraform, con credenciales de la cuenta del piloto.
# Uso: infra/scripts/acceso_usuario.sh 12.345.678-5
set -euo pipefail

INFRA=$(cd "$(dirname "$0")/.." && pwd)
source "$INFRA/scripts/lib/tarea_base.sh"

[ $# -eq 1 ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
RUT=$(echo "$1" | tr -d '. ' | tr 'k' 'K')
[[ $RUT =~ ^[0-9]{6,8}-[0-9K]$ ]] || { echo "RUT con formato 12.345.678-5" >&2; exit 1; }

echo "== Cuenta en Cognito ($RUT) =="
POOL=$(salida cognito_user_pool_id)
if ! aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$RUT" --output table \
    --query '{Estado:UserStatus,Habilitada:Enabled,Creada:UserCreateDate,Modificada:UserLastModifiedDate,MFA:join(`", "`,UserMFASettingList||[`"no"`])}'; then
  echo "No existe una cuenta de Cognito con ese RUT."
fi
cat <<'TXT'
  CONFIRMED              ya definió su contraseña
  FORCE_CHANGE_PASSWORD  aún debe entrar con la clave temporal y cambiarla
  RESET_REQUIRED         debe restablecer su contraseña
TXT

echo
echo "== En Paritario =="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/carga"
cp "$INFRA/scripts/acceso/acceso.sh" "$TMP/carga/cargar.sh"
MOSTRAR_SALIDA=1 ejecutar_en_base "$TMP" acceso-usuario "ACCESO_RUT=$RUT"
