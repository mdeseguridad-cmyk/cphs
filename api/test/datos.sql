-- Datos de prueba de la API (se cargan como dueño, después de cargar.sh).
--   Mutualidad A ── Empresa 1 (contrato A-1, comité C1 en Planta Norte)
--                └─ Empresa 2 (contrato A-2)
--   Empresa 3, cliente directo (comité C3)
SET search_path = paritario, public;

INSERT INTO organismo (rut, nombre, tipo, marca_nombre) VALUES ('70015580-3', 'Mutualidad A', 'mutualidad', 'Comités A');

INSERT INTO empresa (rut, razon_social, organismo_id, codigo_contrato, actividad_economica_codigo)
SELECT '76100200-7', 'Empresa 1', id, 'A-1', '410010' FROM organismo
UNION ALL SELECT '76200300-7', 'Empresa 2', id, 'A-2', NULL FROM organismo;
INSERT INTO empresa (rut, razon_social) VALUES ('76300400-7', 'Empresa 3');

INSERT INTO sucursal (empresa_id, nombre, comuna_id, masa_trabajadores)
SELECT id, 'Planta Norte', 2101, 120 FROM empresa WHERE razon_social = 'Empresa 1';
INSERT INTO comite (empresa_id, sucursal_id, nombre)
SELECT e.id, s.id, 'C1' FROM empresa e JOIN sucursal s ON s.empresa_id = e.id WHERE e.razon_social = 'Empresa 1';
INSERT INTO comite (empresa_id, nombre) SELECT id, 'C3' FROM empresa WHERE razon_social = 'Empresa 3';

INSERT INTO persona (rut, nombres, apellidos, email) VALUES
    ('15151515-0', 'Admin', 'Uno',    'admin1@e1.cl'),
    ('16161616-8', 'Coord', 'Invitado', 'coord@e1.cl'),
    ('12345678-5', 'Audi',  'Tora',   'audi@e1.cl'),
    ('17171717-5', 'Admin', 'Tres',   'admin3@e3.cl'),
    ('14141414-3', 'Admin', 'Org',    'org@a.cl'),
    ('13131313-6', 'Doble', 'Empresa','doble@x.cl');

INSERT INTO usuario (rut, persona_id, cognito_sub, estado)
SELECT p.rut, p.id, v.sub::uuid, v.estado::usuario_estado FROM persona p JOIN (VALUES
    ('15151515-0', '00000000-0000-0000-0000-0000000000a1', 'activo'),
    ('16161616-8', NULL,                                   'invitado'),
    ('12345678-5', '00000000-0000-0000-0000-0000000000a3', 'activo'),
    ('17171717-5', '00000000-0000-0000-0000-0000000000a4', 'activo'),
    ('14141414-3', '00000000-0000-0000-0000-0000000000a5', 'activo'),
    ('13131313-6', '00000000-0000-0000-0000-0000000000a6', 'activo')
) v(rut, sub, estado) ON v.rut = p.rut;

INSERT INTO usuario_rol (usuario_id, rol_id, empresa_id, comite_id)
SELECT u.id, r.id, e.id, c.id
FROM (VALUES
    ('15151515-0', 'ADMIN_EMPRESA', 'Empresa 1', NULL),
    ('16161616-8', 'COORDINADOR',   'Empresa 1', 'C1'),
    ('12345678-5', 'AUDITOR',       'Empresa 1', NULL),
    ('17171717-5', 'ADMIN_EMPRESA', 'Empresa 3', NULL),
    ('13131313-6', 'COORDINADOR',   'Empresa 1', 'C1'),
    ('13131313-6', 'COORDINADOR',   'Empresa 3', NULL)
) v(rut, rol, emp, com)
JOIN usuario u ON u.rut = v.rut JOIN rol r ON r.codigo = v.rol JOIN empresa e ON e.razon_social = v.emp
LEFT JOIN comite c ON c.nombre = v.com;
INSERT INTO usuario_rol (usuario_id, rol_id, organismo_id)
SELECT u.id, r.id, o.id FROM usuario u, rol r, organismo o WHERE u.rut = '14141414-3' AND r.codigo = 'ADMIN_ORGANISMO';

-- Programa general para construcción (sección F).
INSERT INTO programa_plantilla (seccion, nombre) VALUES ('F', 'Programa general de construcción');
INSERT INTO actividad_tipo (plantilla_id, titulo, clasificacion, frecuencia, comision_tipo)
SELECT p.id, v.t, v.c::clasificacion_actividad, v.f::frecuencia, v.k::comision_tipo
FROM programa_plantilla p, (VALUES
    ('Inspección de andamios', 'obligatoria_ley', 'mensual', 'inspeccion_observacion'),
    ('Charla de trabajo en altura', 'recomendada', 'trimestral', 'capacitacion_difusion'),
    ('Revisión del plan de emergencia', 'obligatoria_ley', 'anual', NULL)
) v(t, c, f, k);

-- Integraciones de la Mutualidad A: SSO y listado de empresas.
INSERT INTO integracion (organismo_id, tipo, protocolo, estado, configuracion, secreto_ref)
SELECT id, 'sso'::integracion_tipo, 'SAML', 'activa'::integracion_estado, '{"proveedor": "mutual-a"}'::jsonb, NULL FROM organismo
UNION ALL
SELECT id, 'empresas', 'api', 'activa', '{"mapeo": {"contrato": "nro_adherente"}}', 'paritario-prueba/integraciones/mutual-a' FROM organismo;
INSERT INTO rol_externo (integracion_id, valor, rol_id)
SELECT i.id, v.valor, r.id FROM integracion i, (VALUES ('PREV', 'COORDINADOR'), ('ADM', 'ADMIN_EMPRESA')) v(valor, rol)
JOIN rol r ON r.codigo = v.rol WHERE i.tipo = 'sso';
