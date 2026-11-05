#!/bin/sh
# Carga inicial de la base del piloto. Se ejecuta dentro de la tarea ECS
# "carga-base" (imagen postgres:16-alpine), lanzada por scripts/cargar_base.sh.
#
# Variables (las entrega la definición de la tarea):
#   PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGSSLMODE  usuario maestro
#   APP_DB_PASSWORD                                        clave de paritario_app
#
# Es idempotente: si el esquema ya existe no lo vuelve a crear; el rol de la
# aplicación y sus permisos se actualizan siempre.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
PSQL="psql -X -v ON_ERROR_STOP=1 -q"

: "${APP_DB_PASSWORD:?falta APP_DB_PASSWORD}"

existe=$($PSQL -tAc "SELECT count(*) FROM pg_namespace WHERE nspname = 'paritario'")
if [ "$existe" = "0" ]; then
    echo "Creando esquema y catálogos…"
    # Cada archivo maneja su propia transacción. Si algo falla a medias, borre
    # el esquema (DROP SCHEMA paritario CASCADE) y vuelva a ejecutar.
    $PSQL \
        -f "$DIR/db/schema.sql" \
        -f "$DIR/db/seed.sql" \
        -f "$DIR/db/seed_comunas.sql" \
        -f "$DIR/db/seed_actividades.sql" \
        -f "$DIR/db/seed_sisesat.sql"
else
    echo "El esquema paritario ya existe: no se recrea."
fi

echo "Configurando el rol paritario_app…"
$PSQL -v clave="$APP_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE paritario_app LOGIN PASSWORD %L', :'clave')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'paritario_app')
\gexec
SELECT format('ALTER ROLE paritario_app WITH LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD %L', :'clave')
\gexec
ALTER ROLE paritario_app SET search_path = paritario, public;
GRANT CONNECT ON DATABASE :"DBNAME" TO paritario_app;
GRANT USAGE ON SCHEMA paritario TO paritario_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA paritario TO paritario_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA paritario TO paritario_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA paritario
    GRANT SELECT, INSERT, UPDATE ON TABLES TO paritario_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA paritario
    GRANT USAGE, SELECT ON SEQUENCES TO paritario_app;
SQL

echo "Resumen:"
$PSQL -tAc "SELECT 'comunas: ' || count(*) FROM paritario.comuna
            UNION ALL SELECT 'actividades: ' || count(*) FROM paritario.actividad_economica
            UNION ALL SELECT 'códigos SISESAT: ' || count(*) FROM paritario.codigo_sisesat"
echo "Carga terminada."
