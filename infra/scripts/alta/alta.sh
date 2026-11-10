#!/bin/sh
# Alta de una empresa cliente y de su primer administrador. Se ejecuta dentro
# de la tarea de un solo uso, como administrador de la base (la aplicación no
# puede crear empresas). Lo lanza scripts/alta_empresa.sh.
#
# Variables: ALTA_RUT_EMPRESA, ALTA_RAZON_SOCIAL, ALTA_ACTIVIDAD (opcional),
# ALTA_ORGANISMO_ADMINISTRADOR (sigla, opcional), ALTA_RUT_ADMIN,
# ALTA_NOMBRES, ALTA_APELLIDOS, ALTA_CORREO.
#
# Idempotente: si la empresa, la persona, el usuario o su acceso ya existen,
# no los duplica. Los valores entran como variables de psql (:'variable'),
# nunca concatenados en el SQL.
set -eu

psql -X -v ON_ERROR_STOP=1 -q <<'SQL'
\getenv rut_empresa ALTA_RUT_EMPRESA
\getenv razon ALTA_RAZON_SOCIAL
\getenv actividad ALTA_ACTIVIDAD
\getenv oa ALTA_ORGANISMO_ADMINISTRADOR
\getenv rut_admin ALTA_RUT_ADMIN
\getenv nombres ALTA_NOMBRES
\getenv apellidos ALTA_APELLIDOS
\getenv correo ALTA_CORREO
SET search_path = paritario, public;
BEGIN;

INSERT INTO empresa (rut, razon_social, actividad_economica_codigo, organismo_administrador_id)
VALUES (:'rut_empresa', :'razon', nullif(:'actividad', ''),
        (SELECT id FROM organismo_administrador WHERE sigla = nullif(:'oa', '')))
ON CONFLICT (rut) DO NOTHING;

INSERT INTO persona (rut, nombres, apellidos, email)
VALUES (:'rut_admin', :'nombres', :'apellidos', :'correo')
ON CONFLICT (rut) DO NOTHING;

INSERT INTO usuario (rut, persona_id, estado)
SELECT :'rut_admin', id, 'invitado' FROM persona WHERE rut = :'rut_admin'
ON CONFLICT (rut) DO NOTHING;

INSERT INTO usuario_rol (usuario_id, rol_id, empresa_id, origen)
SELECT u.id, r.id, e.id, 'manual'
FROM usuario u, rol r, empresa e
WHERE u.rut = :'rut_admin' AND r.codigo = 'ADMIN_EMPRESA' AND e.rut = :'rut_empresa'
  AND NOT EXISTS (SELECT 1 FROM usuario_rol x
                  WHERE x.usuario_id = u.id AND x.rol_id = r.id AND x.empresa_id = e.id AND x.vigente);

COMMIT;

SELECT format('Empresa: %s (%s) · administrador: %s · estado de su cuenta: %s',
              e.razon_social, e.rut, u.rut, u.estado)
FROM empresa e, usuario u WHERE e.rut = :'rut_empresa' AND u.rut = :'rut_admin';
SQL
