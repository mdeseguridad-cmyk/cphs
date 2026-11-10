#!/usr/bin/env bash
# Carga el esquema y los catálogos en la base del piloto, desde su computador.
# Corre dentro de AWS como tarea de un solo uso (ver scripts/lib/tarea_base.sh).
#
# Requisitos: aws CLI v2 y terraform, con credenciales de la cuenta del piloto,
# y haber ejecutado "terraform apply" en infra/.
# Uso: infra/scripts/cargar_base.sh
set -euo pipefail

INFRA=$(cd "$(dirname "$0")/.." && pwd)
RAIZ=$(cd "$INFRA/.." && pwd)
source "$INFRA/scripts/lib/tarea_base.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/carga/db"
cp "$RAIZ"/db/schema.sql "$RAIZ"/db/seed*.sql "$TMP/carga/db/"
cp "$INFRA/scripts/carga/cargar.sh" "$TMP/carga/"

ejecutar_en_base "$TMP" carga-base
echo "Carga terminada correctamente."
