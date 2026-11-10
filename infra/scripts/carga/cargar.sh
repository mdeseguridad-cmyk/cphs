#!/bin/sh
# Carga inicial de la base del piloto. Se ejecuta dentro de la tarea ECS
# "carga-base" (imagen postgres:16-alpine), lanzada por scripts/cargar_base.sh.
#
# Variables (las entrega la definición de la tarea):
#   PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGSSLMODE  usuario maestro
#   APP_DB_USUARIO                                         rol de la aplicación
#
# El rol de la aplicación no tiene clave: en RDS se le otorga rds_iam y la
# API se conecta con tokens de IAM.
#
# Es idempotente: si el esquema ya existe no lo vuelve a crear; el rol de la
# aplicación y sus permisos se actualizan siempre.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
PSQL="psql -X -v ON_ERROR_STOP=1 -q"

APP=${APP_DB_USUARIO:-paritario_app}

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

echo "Configurando el rol $APP…"
$PSQL -v app="$APP" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'app')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app')
\gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD NULL', :'app')
\gexec
-- rds_iam solo existe en RDS: habilita el ingreso con token de IAM.
SELECT format('GRANT rds_iam TO %I', :'app')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rds_iam')
\gexec
SELECT format('ALTER ROLE %I SET search_path = paritario, public', :'app') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app') \gexec
SELECT format('GRANT USAGE ON SCHEMA paritario TO %I', :'app') \gexec
SELECT format('GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA paritario TO %I', :'app') \gexec
SELECT format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA paritario TO %I', :'app') \gexec
-- Las únicas filas que la aplicación borra: miembros de una comisión (se
-- reemplazan al editarla). Todo lo demás se marca, nunca se borra.
SELECT format('GRANT DELETE ON paritario.comision_integrante TO %I', :'app') \gexec
-- La bitácora de accesos solo se inserta: la aplicación no puede modificarla.
SELECT format('REVOKE UPDATE ON paritario.log_acceso FROM %I', :'app') \gexec
-- Funciones de integración (importar empresas y centros, accesos del SSO).
SELECT format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA paritario TO %I', :'app') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA paritario GRANT SELECT, INSERT, UPDATE ON TABLES TO %I', :'app') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA paritario GRANT USAGE, SELECT ON SEQUENCES TO %I', :'app') \gexec
SQL

echo "Resumen:"
$PSQL -tAc "SELECT 'comunas: ' || count(*) FROM paritario.comuna
            UNION ALL SELECT 'actividades: ' || count(*) FROM paritario.actividad_economica
            UNION ALL SELECT 'códigos SISESAT: ' || count(*) FROM paritario.codigo_sisesat"
echo "Carga terminada."
