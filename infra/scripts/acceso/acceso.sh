#!/bin/sh
# Muestra los accesos de un usuario en Paritario. Se ejecuta dentro de la
# tarea de un solo uso, como administrador de la base, y solo lee. Lo lanza
# scripts/acceso_usuario.sh.
#
# Variable: ACCESO_RUT (sin puntos, con guion). No muestra correos ni otros
# datos de contacto: la salida queda en los registros de la tarea.
set -eu

psql -X -v ON_ERROR_STOP=1 -q <<'SQL'
\getenv rut ACCESO_RUT
SET search_path = paritario, public;
\pset footer off
\echo '== Usuario =='
SELECT u.rut, u.estado, u.cognito_sub IS NOT NULL AS ingreso_alguna_vez,
       to_char(u.ultimo_acceso AT TIME ZONE 'America/Santiago', 'YYYY-MM-DD HH24:MI') AS ultimo_acceso,
       concat_ws(' ', p.nombres, p.apellidos) AS nombre
  FROM usuario u LEFT JOIN persona p ON p.id = u.persona_id
 WHERE u.rut = :'rut';
\echo '== Accesos =='
SELECT r.codigo AS rol, coalesce(e.razon_social, o.nombre) AS ambito, c.nombre AS comite,
       ur.origen, CASE WHEN ur.vigente THEN 'sí' ELSE 'no' END AS vigente
  FROM usuario u
  JOIN usuario_rol ur ON ur.usuario_id = u.id
  JOIN rol r ON r.id = ur.rol_id
  LEFT JOIN empresa e ON e.id = ur.empresa_id
  LEFT JOIN organismo o ON o.id = ur.organismo_id
  LEFT JOIN comite c ON c.id = ur.comite_id
 WHERE u.rut = :'rut'
 ORDER BY ur.vigente DESC, ur.id;
SQL
