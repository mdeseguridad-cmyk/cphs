-- =============================================================================
-- Paritario — prueba de aislamiento (Row-Level Security) y reglas de negocio.
--
-- Uso, sobre una base de prueba vacía:
--   psql -v ON_ERROR_STOP=1 -f db/schema.sql -f db/seed.sql -f db/seed_comunas.sql \
--        -f db/seed_actividades.sql -f db/seed_sisesat.sql -f db/test_rls.sql
--
-- Cada verificación que falla aborta el script con un mensaje claro.
-- Todo corre dentro de una transacción que se revierte al final: no deja datos.
-- =============================================================================

\set ON_ERROR_STOP on
\o /dev/null
BEGIN;
SET search_path = paritario, public;

-- Rol con el que se conecta la aplicación: sin privilegios de dueño, por lo
-- tanto sujeto a la seguridad por fila.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'paritario_app') THEN
        CREATE ROLE paritario_app NOLOGIN;
    END IF;
END $$;
GRANT USAGE ON SCHEMA paritario TO paritario_app;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA paritario TO paritario_app;
REVOKE UPDATE ON log_acceso FROM paritario_app;  -- como en cargar.sh

-- -----------------------------------------------------------------------------
-- Datos de prueba (cargados como dueño)
--   Organismo A  ── Empresa 1 (comités C1, C2)
--                └─ Empresa 2 (comité C3)
--   Organismo B  ── (sin empresas)
--   Empresa 3, cliente directo (comité C4)
-- -----------------------------------------------------------------------------
INSERT INTO organismo (rut, nombre, tipo, marca_nombre, color_primario, dominio) VALUES
    ('70015580-3', 'Mutualidad A', 'mutualidad', 'Comités A', '#2563eb', 'comites.a.cl'),
    ('70016330-K', 'Servicio B',   'servicio_publico', 'Comités B', '#0f766e', 'comites.b.cl');

UPDATE organismo SET organismo_administrador_id = (SELECT id FROM organismo_administrador WHERE sigla = 'IST')
WHERE nombre = 'Mutualidad A';

INSERT INTO empresa (rut, razon_social, organismo_id, organismo_administrador_id) VALUES
    ('76100200-7', 'Empresa 1', (SELECT id FROM organismo WHERE nombre = 'Mutualidad A'), (SELECT id FROM organismo_administrador WHERE sigla = 'IST')),
    ('76200300-7', 'Empresa 2', (SELECT id FROM organismo WHERE nombre = 'Mutualidad A'), (SELECT id FROM organismo_administrador WHERE sigla = 'IST')),
    ('76300400-7', 'Empresa 3', NULL, (SELECT id FROM organismo_administrador WHERE sigla = 'ACHS'));

-- Empresa 1 es constructora (código SII 410010, sección F) y hay una
-- plantilla general de programa para construcción y otra para comercio.
UPDATE empresa SET actividad_economica_codigo = '410010' WHERE razon_social = 'Empresa 1';
INSERT INTO programa_plantilla (seccion, nombre) VALUES
    ('F', 'Programa general de construcción'),
    ('G', 'Programa general de comercio');

INSERT INTO comite (empresa_id, nombre)
SELECT e.id, v.nombre FROM (VALUES ('Empresa 1','C1'), ('Empresa 1','C2'), ('Empresa 2','C3'), ('Empresa 3','C4')) v(emp, nombre)
JOIN empresa e ON e.razon_social = v.emp;

INSERT INTO persona (rut, nombres, apellidos) VALUES
    ('11111111-1', 'Ana',   'Uno'),     -- integrante de C1
    ('12345678-5', 'Bruno', 'Dos'),     -- integrante de C3
    ('13131313-6', 'Carla', 'Tres'),    -- integrante de C4
    ('14141414-3', 'Admin', 'Org A'),
    ('15151515-0', 'Admin', 'Empresa 1'),
    ('16161616-8', 'Coord', 'C1'),
    ('17171717-5', 'Admin', 'Empresa 3'),
    ('18181818-2', 'Diego', 'Afectado');  -- trabajador accidentado, no integra el comité

INSERT INTO comite_integrante (comite_id, persona_id, tipo, representacion, cargo)
SELECT c.id, p.id, 'titular', 'trabajadores', 'presidente'
FROM (VALUES ('C1','11111111-1'), ('C3','12345678-5'), ('C4','13131313-6')) v(com, rut)
JOIN comite c ON c.nombre = v.com JOIN persona p ON p.rut = v.rut;

INSERT INTO reunion (comite_id, anio, mes, numero, estado, fecha_realizada)
SELECT c.id, 2026, 1, 1, 'realizada', '2026-01-15' FROM comite c;

INSERT INTO documento (comite_id, tipo, nombre, archivo_key, contiene_datos_sensibles)
SELECT c.id, 'investigacion', 'Investigación ' || c.nombre, 's3://doc/' || c.nombre, true FROM comite c;

-- Investigación de un accidente en C1, con códigos SISESAT ficticios de prueba.
INSERT INTO codigo_sisesat (clasificacion, codigo, descripcion) VALUES
    ('forma_accidente', 'PRUEBA-F', 'Forma de prueba'),
    ('agente_material', 'PRUEBA-A', 'Agente de prueba');
INSERT INTO investigacion_accidente (comite_id, persona_id, tipo, gravedad, fecha_evento, descripcion, dias_perdidos, forma_id, agente_accidente_id)
SELECT c.id, p.id, 'accidente_trabajo', 'grave', '2026-03-10 10:30-03', 'Caída desde altura en bodega', 15,
       (SELECT id FROM codigo_sisesat WHERE codigo = 'PRUEBA-F'), (SELECT id FROM codigo_sisesat WHERE codigo = 'PRUEBA-A')
FROM comite c, persona p WHERE c.nombre = 'C1' AND p.rut = '18181818-2';
INSERT INTO investigacion_causa (investigacion_id, tipo, descripcion)
SELECT id, 'basica', 'Falta de procedimiento de trabajo en altura' FROM investigacion_accidente;
INSERT INTO investigacion_medida (investigacion_id, jerarquia, descripcion)
SELECT id, 'control_ingenieria', 'Instalar barandas en el entrepiso' FROM investigacion_accidente;

INSERT INTO usuario (rut, persona_id)
SELECT rut, id FROM persona WHERE rut IN ('14141414-3','15151515-0','16161616-8','17171717-5');

-- Asignaciones de rol con su ámbito.
INSERT INTO usuario_rol (usuario_id, rol_id, organismo_id)
SELECT u.id, 1, o.id FROM usuario u, organismo o WHERE u.rut = '14141414-3' AND o.nombre = 'Mutualidad A';
INSERT INTO usuario_rol (usuario_id, rol_id, empresa_id)
SELECT u.id, 3, e.id FROM usuario u, empresa e WHERE u.rut = '15151515-0' AND e.razon_social = 'Empresa 1';
INSERT INTO usuario_rol (usuario_id, rol_id, empresa_id, comite_id)
SELECT u.id, 4, c.empresa_id, c.id FROM usuario u, comite c WHERE u.rut = '16161616-8' AND c.nombre = 'C1';
INSERT INTO usuario_rol (usuario_id, rol_id, empresa_id)
SELECT u.id, 3, e.id FROM usuario u, empresa e WHERE u.rut = '17171717-5' AND e.razon_social = 'Empresa 3';

-- Guardamos los ids de usuario para usarlos después del SET ROLE.
CREATE TEMP TABLE t_usuarios AS SELECT rut, id FROM usuario;
GRANT SELECT ON t_usuarios TO paritario_app;

-- -----------------------------------------------------------------------------
-- Función de verificación
-- -----------------------------------------------------------------------------
CREATE FUNCTION pg_temp.verificar(descripcion text, obtenido bigint, esperado bigint)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF obtenido IS DISTINCT FROM esperado THEN
        RAISE EXCEPTION 'FALLA: % (obtenido %, esperado %)', descripcion, obtenido, esperado;
    END IF;
    RAISE NOTICE 'ok  %', descripcion;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.verificar(text, bigint, bigint) TO paritario_app;

-- -----------------------------------------------------------------------------
-- 1. Aislamiento por perfil
-- -----------------------------------------------------------------------------
SET ROLE paritario_app;

-- Sin usuario en la sesión, no se ve nada.
SELECT pg_temp.verificar('sin sesión: empresas visibles', (SELECT count(*) FROM empresa), 0);
SELECT pg_temp.verificar('sin sesión: personas visibles', (SELECT count(*) FROM persona), 0);

-- Administrador del Organismo A: ve sus 2 empresas y sus 3 comités (indicadores),
-- pero no personas, integrantes ni documentos.
SELECT set_config('app.usuario_id', (SELECT id::text FROM t_usuarios WHERE rut = '14141414-3'), true);
SELECT pg_temp.verificar('organismo A: empresas', (SELECT count(*) FROM empresa), 2);
SELECT pg_temp.verificar('organismo A: comités', (SELECT count(*) FROM comite), 3);
SELECT pg_temp.verificar('organismo A: reuniones (indicadores)', (SELECT count(*) FROM reunion), 3);
SELECT pg_temp.verificar('organismo A: personas de comités', (SELECT count(*) FROM persona WHERE rut IN ('11111111-1','12345678-5','13131313-6')), 0);
SELECT pg_temp.verificar('organismo A: integrantes', (SELECT count(*) FROM comite_integrante), 0);
SELECT pg_temp.verificar('organismo A: documentos', (SELECT count(*) FROM documento), 0);
SELECT pg_temp.verificar('organismo A: organismos visibles', (SELECT count(*) FROM organismo), 1);
SELECT pg_temp.verificar('organismo A: cumplimiento visible', (SELECT count(*) FROM v_cumplimiento_reuniones), 3);
SELECT pg_temp.verificar('organismo A: no ve casos de accidentes', (SELECT count(*) FROM investigacion_accidente), 0);
SELECT pg_temp.verificar('organismo A: no ve a la persona accidentada', (SELECT count(*) FROM persona WHERE rut = '18181818-2'), 0);
SELECT pg_temp.verificar('organismo A: ve el total de accidentes graves', (SELECT sum(graves)::bigint FROM v_indicadores_siniestralidad), 1);

-- Administrador de Empresa 1: ve su empresa, sus 2 comités y el detalle.
SELECT set_config('app.usuario_id', (SELECT id::text FROM t_usuarios WHERE rut = '15151515-0'), true);
SELECT pg_temp.verificar('empresa 1: empresas', (SELECT count(*) FROM empresa), 1);
SELECT pg_temp.verificar('empresa 1: comités', (SELECT count(*) FROM comite), 2);
SELECT pg_temp.verificar('empresa 1: integrantes', (SELECT count(*) FROM comite_integrante), 1);
SELECT pg_temp.verificar('empresa 1: documentos', (SELECT count(*) FROM documento), 2);
SELECT pg_temp.verificar('empresa 1: no ve la persona de Empresa 2', (SELECT count(*) FROM persona WHERE rut = '12345678-5'), 0);
SELECT pg_temp.verificar('empresa 1: ve la marca de su organismo', (SELECT count(*) FROM organismo), 1);
SELECT pg_temp.verificar('empresa 1: no ve integraciones del organismo', (SELECT count(*) FROM integracion), 0);
SELECT pg_temp.verificar('empresa 1: ve la investigación de C1', (SELECT count(*) FROM investigacion_accidente), 1);
SELECT pg_temp.verificar('empresa 1: ve a la persona accidentada', (SELECT count(*) FROM persona WHERE rut = '18181818-2'), 1);
SELECT pg_temp.verificar('empresa 1: ve causas y medidas', (SELECT count(*) FROM investigacion_causa) + (SELECT count(*) FROM investigacion_medida), 2);
SELECT pg_temp.verificar('empresa 1: su rubro (sección CIIU) es construcción',
    (SELECT count(*) FROM empresa e JOIN actividad_economica a ON a.codigo = e.actividad_economica_codigo WHERE a.seccion = 'F'), 1);
SELECT pg_temp.verificar('empresa 1: se le propone solo la plantilla de su rubro',
    (SELECT count(*) FROM empresa e
     JOIN actividad_economica a ON a.codigo = e.actividad_economica_codigo
     JOIN programa_plantilla pp ON pp.seccion = a.seccion), 1);

-- Coordinador de C1: solo su comité.
SELECT set_config('app.usuario_id', (SELECT id::text FROM t_usuarios WHERE rut = '16161616-8'), true);
SELECT pg_temp.verificar('coordinador C1: comités', (SELECT count(*) FROM comite), 1);
SELECT pg_temp.verificar('coordinador C1: documentos', (SELECT count(*) FROM documento), 1);
SELECT pg_temp.verificar('coordinador C1: ve la investigación de su comité', (SELECT count(*) FROM investigacion_accidente), 1);

-- Administrador de Empresa 3 (cliente directo): nada de la Mutualidad A.
SELECT set_config('app.usuario_id', (SELECT id::text FROM t_usuarios WHERE rut = '17171717-5'), true);
SELECT pg_temp.verificar('empresa 3: empresas', (SELECT count(*) FROM empresa), 1);
SELECT pg_temp.verificar('empresa 3: comités', (SELECT count(*) FROM comite), 1);
SELECT pg_temp.verificar('empresa 3: organismos', (SELECT count(*) FROM organismo), 0);
SELECT pg_temp.verificar('empresa 3: no ve comités de otras empresas', (SELECT count(*) FROM comite WHERE nombre IN ('C1','C2','C3')), 0);
SELECT pg_temp.verificar('catálogo de organismos administradores visible para todos', (SELECT count(*) FROM organismo_administrador), 4);
SELECT pg_temp.verificar('empresa 3: no ve investigaciones de otras empresas', (SELECT count(*) FROM investigacion_accidente), 0);
SELECT pg_temp.verificar('empresa 3: no ve indicadores de otras empresas', (SELECT count(*) FROM v_indicadores_siniestralidad), 0);
SELECT pg_temp.verificar('empresa 3: su organismo administrador es ACHS (3111)',
    (SELECT count(*) FROM empresa e JOIN organismo_administrador oa ON oa.id = e.organismo_administrador_id WHERE oa.codigo_suseso = '3111'), 1);

-- Escritura: el administrador de Empresa 3 puede crear un comité en su empresa…
SELECT set_config('app.usuario_id', (SELECT id::text FROM t_usuarios WHERE rut = '17171717-5'), true);
INSERT INTO comite (empresa_id, nombre) SELECT id, 'C5' FROM empresa;  -- solo ve la suya
SELECT pg_temp.verificar('empresa 3: creó su comité', (SELECT count(*) FROM comite WHERE nombre = 'C5'), 1);

-- …pero no en una empresa ajena.
RESET ROLE;
CREATE TEMP TABLE t_empresa1 AS SELECT id FROM empresa WHERE razon_social = 'Empresa 1';
GRANT SELECT ON t_empresa1 TO paritario_app;
SET ROLE paritario_app;
SELECT set_config('app.usuario_id', (SELECT id::text FROM t_usuarios WHERE rut = '17171717-5'), true);
DO $$
DECLARE bloqueado boolean := false;
BEGIN
    BEGIN
        INSERT INTO comite (empresa_id, nombre) VALUES ((SELECT id FROM t_empresa1), 'Intruso');
    EXCEPTION WHEN insufficient_privilege THEN bloqueado := true;
    END;
    IF NOT bloqueado THEN
        RAISE EXCEPTION 'FALLA: empresa 3 pudo crear un comité en empresa 1';
    END IF;
    RAISE NOTICE 'ok  empresa 3: no puede crear comités en otra empresa';
END $$;

RESET ROLE;

-- -----------------------------------------------------------------------------
-- 2. Reglas de negocio
-- -----------------------------------------------------------------------------
CREATE FUNCTION pg_temp.debe_fallar(descripcion text, sentencia text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE sentencia;
    EXCEPTION WHEN others THEN
        RAISE NOTICE 'ok  % (rechazado: %)', descripcion, SQLERRM;
        RETURN;
    END;
    RAISE EXCEPTION 'FALLA: se aceptó % ', descripcion;
END $$;

SELECT pg_temp.debe_fallar('RUT con dígito verificador incorrecto',
    $q$INSERT INTO persona (rut, nombres, apellidos) VALUES ('11111111-2', 'X', 'Y')$q$);
SELECT pg_temp.debe_fallar('RUT con puntos',
    $q$INSERT INTO persona (rut, nombres, apellidos) VALUES ('11.111.111-1', 'X', 'Y')$q$);
SELECT pg_temp.debe_fallar('segundo presidente vigente en C1',
    $q$INSERT INTO comite_integrante (comite_id, persona_id, tipo, representacion, cargo)
       SELECT c.id, p.id, 'titular', 'empresa', 'presidente' FROM comite c, persona p
       WHERE c.nombre = 'C1' AND p.rut = '15151515-0'$q$);
SELECT pg_temp.debe_fallar('aforado que no es titular de los trabajadores',
    $q$INSERT INTO comite_integrante (comite_id, persona_id, tipo, representacion, es_aforado)
       SELECT c.id, p.id, 'suplente', 'empresa', true FROM comite c, persona p
       WHERE c.nombre = 'C2' AND p.rut = '15151515-0'$q$);
SELECT pg_temp.debe_fallar('comité de baja sin fecha de disolución',
    $q$UPDATE comite SET estado = 'baja' WHERE nombre = 'C2'$q$);
SELECT pg_temp.debe_fallar('reunión realizada sin fecha',
    $q$INSERT INTO reunion (comite_id, anio, mes, numero, estado)
       SELECT id, 2026, 2, 2, 'realizada' FROM comite WHERE nombre = 'C1'$q$);
SELECT pg_temp.debe_fallar('rol de empresa asignado con ámbito de organismo',
    $q$INSERT INTO usuario_rol (usuario_id, rol_id, organismo_id)
       SELECT u.id, 3, o.id FROM usuario u, organismo o WHERE u.rut = '15151515-0' AND o.nombre = 'Mutualidad A'$q$);
SELECT pg_temp.debe_fallar('coordinador con comité de otra empresa',
    $q$INSERT INTO usuario_rol (usuario_id, rol_id, empresa_id, comite_id)
       SELECT u.id, 4, e.id, c.id FROM usuario u, empresa e, comite c
       WHERE u.rut = '16161616-8' AND e.razon_social = 'Empresa 1' AND c.nombre = 'C3'$q$);
SELECT pg_temp.debe_fallar('comisión personalizada sin nombre',
    $q$INSERT INTO comision (comite_id, tipo) SELECT id, 'personalizada' FROM comite WHERE nombre = 'C1'$q$);
-- Códigos SISESAT oficiales (Anexos II, III y IV) y sugerencias de forma y agente.
SELECT pg_temp.verificar('SISESAT: 60 formas (Anexo II)', (SELECT count(*) FROM codigo_sisesat WHERE clasificacion = 'forma_accidente' AND codigo NOT LIKE 'PRUEBA%'), 60);
SELECT pg_temp.verificar('SISESAT: 145 agentes (Anexo III)', (SELECT count(*) FROM codigo_sisesat WHERE clasificacion = 'agente_material' AND codigo NOT LIKE 'PRUEBA%'), 145);
SELECT pg_temp.verificar('SISESAT: 3300 causas externas (Anexo IV)', (SELECT count(*) FROM codigo_sisesat WHERE clasificacion = 'causa_externa_cie10'), 3300);
SELECT pg_temp.verificar('SISESAT: caída al mismo nivel W01.0 sugiere la forma 12.1',
    (SELECT count(*) FROM sugerencias_sisesat('W010') WHERE clasificacion = 'forma_accidente' AND codigo = '12.1'), 1);
SELECT pg_temp.verificar('SISESAT: W01.0 sugiere el agente 690',
    (SELECT count(*) FROM sugerencias_sisesat('W010') WHERE clasificacion = 'agente_material' AND codigo = '690'), 1);
SELECT pg_temp.verificar('SISESAT: agente 234 sugiere sus 6 subcódigos (234.1 a 234.6)',
    (SELECT count(*) FROM sugerencias_sisesat('V020') WHERE clasificacion = 'agente_material' AND codigo LIKE '234.%'), 6);
SELECT pg_temp.verificar('SISESAT: equivalencias con anomalía anotada', (SELECT count(*) FROM equivalencia_cie10_oit WHERE observacion IS NOT NULL), 108);
SELECT pg_temp.verificar('SISESAT: 1421 naturalezas de lesión (Anexo V)', (SELECT count(*) FROM codigo_sisesat WHERE clasificacion = 'lesion_cie10'), 1421);
SELECT pg_temp.verificar('SISESAT: S02.00 conserva sus términos adicionales (hueso frontal)',
    (SELECT count(*) FROM codigo_sisesat WHERE clasificacion = 'lesion_cie10' AND codigo = 'S0200' AND 'FRACTURA CERRADA DEL HUESO FRONTAL' = ANY (terminos)), 1);
SELECT pg_temp.verificar('SISESAT: 142 ubicaciones anatómicas (Anexo VI)', (SELECT count(*) FROM codigo_sisesat WHERE clasificacion = 'ubicacion_lesion'), 142);
SELECT pg_temp.verificar('SISESAT: oreja derecha 1.2.1 tiene grafía 121',
    (SELECT count(*) FROM codigo_sisesat WHERE clasificacion = 'ubicacion_lesion' AND codigo = '1.2.1' AND codigo_alterno = '121'), 1);
SELECT pg_temp.verificar('SISESAT: 3573 agentes de enfermedad (Anexo IX)', (SELECT count(*) FROM codigo_sisesat WHERE clasificacion = 'agente_enfermedad'), 3573);
SELECT pg_temp.verificar('SISESAT: 503 agrupaciones del Anexo IX no seleccionables',
    (SELECT count(*) FROM codigo_sisesat WHERE clasificacion = 'agente_enfermedad' AND NOT seleccionable), 503);

-- Enfermedad profesional codificada con un ítem individual del Anexo IX.
INSERT INTO investigacion_accidente (comite_id, tipo, fecha_evento, descripcion, agente_enfermedad_id)
SELECT c.id, 'enfermedad_profesional', '2026-04-01', 'Exposición a sílice', cs.id
FROM comite c, codigo_sisesat cs
WHERE c.nombre = 'C1' AND cs.clasificacion = 'agente_enfermedad' AND cs.codigo = '1101000001';
SELECT pg_temp.verificar('SISESAT: enfermedad profesional con ítem individual aceptada',
    (SELECT count(*) FROM investigacion_accidente WHERE tipo = 'enfermedad_profesional'), 1);
SELECT pg_temp.debe_fallar('código SISESAT de otra clasificación (agente usado como forma)',
    $q$UPDATE investigacion_accidente SET forma_id = (SELECT id FROM codigo_sisesat WHERE codigo = 'PRUEBA-A')$q$);
SELECT pg_temp.debe_fallar('enfermedad profesional codificada con forma de accidente',
    $q$UPDATE investigacion_accidente SET tipo = 'enfermedad_profesional'$q$);
SELECT pg_temp.debe_fallar('accidente con diagnóstico de enfermedad profesional',
    $q$INSERT INTO codigo_sisesat (clasificacion, codigo, descripcion) VALUES ('enfermedad_cie10', 'PRUEBA-E', 'Diagnóstico de prueba');
       UPDATE investigacion_accidente SET diagnostico_enfermedad_id = (SELECT id FROM codigo_sisesat WHERE codigo = 'PRUEBA-E')$q$);
SELECT pg_temp.debe_fallar('agente de enfermedad que es una agrupación del Anexo IX',
    $q$UPDATE investigacion_accidente SET agente_enfermedad_id =
         (SELECT id FROM codigo_sisesat WHERE clasificacion = 'agente_enfermedad' AND codigo = '1100000000')
       WHERE tipo = 'enfermedad_profesional'$q$);
SELECT pg_temp.debe_fallar('investigación cerrada sin fecha de cierre',
    $q$UPDATE investigacion_accidente SET estado = 'cerrada'$q$);
SELECT pg_temp.debe_fallar('empresa con código de actividad inexistente',
    $q$UPDATE empresa SET actividad_economica_codigo = '999999' WHERE razon_social = 'Empresa 2'$q$);
SELECT pg_temp.debe_fallar('código SUSESO con formato inválido',
    $q$INSERT INTO organismo_administrador (id, sigla, nombre, tipo, codigo_suseso) VALUES (9, 'X', 'Prueba', 'otro', '31A1')$q$);
SELECT pg_temp.debe_fallar('usuario activo sin cuenta de Cognito',
    $q$UPDATE usuario SET estado = 'activo' WHERE rut = '15151515-0'$q$);
SELECT pg_temp.debe_fallar('documento disponible sin huella ni tamaño',
    $q$UPDATE documento SET estado = 'disponible' WHERE nombre = 'Investigación C1'$q$);
INSERT INTO log_acceso (usuario_id, accion, entidad, entidad_id) SELECT id, 'ver', 'documento', 1 FROM usuario LIMIT 1;
SET ROLE paritario_app;
SELECT pg_temp.debe_fallar('la aplicación modifica la bitácora de accesos',
    $q$UPDATE log_acceso SET accion = 'editar'$q$);
RESET ROLE;
SELECT pg_temp.debe_fallar('investigación sin marca de datos de salud',
    $q$UPDATE documento SET contiene_datos_sensibles = false WHERE nombre = 'Investigación C1'$q$);
SELECT pg_temp.debe_fallar('huella SHA-256 mal formada',
    $q$UPDATE documento SET sha256 = 'abc' WHERE nombre = 'Investigación C1'$q$);
UPDATE documento SET estado = 'disponible', tamano_bytes = 1024, sha256 = repeat('a', 64)
WHERE nombre = 'Investigación C1';
SELECT pg_temp.verificar('documento disponible con huella y tamaño',
    (SELECT count(*) FROM documento WHERE nombre = 'Investigación C1' AND estado = 'disponible'), 1);
SELECT pg_temp.debe_fallar('transferencia internacional sin salvaguarda',
    $q$INSERT INTO encargado_tratamiento (nombre, tipo, pais, transferencia_internacional)
       VALUES ('Nube', 'nube', 'Brasil', true)$q$);

-- Una reunión planificada de un mes ya terminado cuenta como exigida e incumplida.
INSERT INTO reunion (comite_id, anio, mes, numero) SELECT id, 2026, 2, 2 FROM comite WHERE nombre = 'C1';
SELECT pg_temp.verificar('cumplimiento: febrero vencido sin registro baja C1 a 50 %',
    (SELECT (exigidas * 1000 + porcentaje * 10)::bigint FROM v_cumplimiento_reuniones v JOIN comite c ON c.id = v.comite_id
     WHERE c.nombre = 'C1' AND v.anio = 2026), 2500);

-- Bitácora de accesos separada por empresa: la lee solo su administrador y
-- nadie escribe a nombre de otro ni fuera de su ámbito.
INSERT INTO log_acceso (usuario_id, empresa_id, accion, entidad, entidad_id)
SELECT u.id, e.id, 'ver', 'comite', 1 FROM usuario u, empresa e
WHERE u.rut = '15151515-0' AND e.razon_social IN ('Empresa 1', 'Empresa 3');
CREATE FUNCTION pg_temp.como(p_rut text) RETURNS void LANGUAGE sql AS $$
    SELECT set_config('app.usuario_id', (SELECT id::text FROM t_usuarios WHERE rut = p_rut), true)
$$;
GRANT EXECUTE ON FUNCTION pg_temp.como(text) TO paritario_app;
CREATE TEMP TABLE t_empresas AS SELECT razon_social, id FROM empresa;
GRANT SELECT ON t_empresas TO paritario_app;
SET ROLE paritario_app;
SELECT pg_temp.como('15151515-0');
SELECT pg_temp.verificar('bitácora: el administrador de Empresa 1 ve solo las entradas de su empresa',
    (SELECT count(*) FROM log_acceso WHERE empresa_id = (SELECT id FROM empresa WHERE razon_social = 'Empresa 1')) * 10
    + (SELECT count(*) FROM log_acceso), 11);
INSERT INTO log_acceso (usuario_id, empresa_id, accion, entidad, entidad_id)
SELECT usuario_actual(), id, 'ver', 'documento', 1 FROM empresa WHERE razon_social = 'Empresa 1';
SELECT pg_temp.verificar('bitácora: registra a su nombre en su empresa', (SELECT count(*) FROM log_acceso), 2);
SELECT pg_temp.debe_fallar('bitácora: registrar a nombre de otro usuario',
    $q$INSERT INTO log_acceso (usuario_id, empresa_id, accion) SELECT id, NULL, 'ver' FROM t_usuarios WHERE rut = '17171717-5'$q$);
SELECT pg_temp.debe_fallar('bitácora: registrar en una empresa fuera de su ámbito',
    $q$INSERT INTO log_acceso (usuario_id, empresa_id, accion) SELECT usuario_actual(), id, 'ver' FROM t_empresas WHERE razon_social = 'Empresa 3'$q$);
SELECT pg_temp.como('17171717-5');
SELECT pg_temp.verificar('bitácora: el administrador de Empresa 3 ve solo la suya', (SELECT count(*) FROM log_acceso), 1);
SELECT pg_temp.como('16161616-8');
SELECT pg_temp.verificar('bitácora: un coordinador no la consulta', (SELECT count(*) FROM log_acceso), 0);
SELECT pg_temp.como('14141414-3');
SELECT pg_temp.verificar('bitácora: el organismo no la consulta', (SELECT count(*) FROM log_acceso), 0);
RESET ROLE;
SELECT set_config('app.usuario_id', '', true);

-- Vista de paridad: C1 tiene un solo titular de trabajadores, no es paritario.
SELECT pg_temp.verificar('paridad: C1 no es paritario',
    (SELECT count(*) FROM v_paridad_comite v JOIN comite c ON c.id = v.comite_id
     WHERE c.nombre = 'C1' AND NOT v.es_paritario), 1);


-- -----------------------------------------------------------------------------
-- 3. Integraciones: empresas, centros y accesos desde el SSO del cliente
-- -----------------------------------------------------------------------------
RESET ROLE;
INSERT INTO integracion (organismo_id, tipo, protocolo, estado)
SELECT o.id, t, 'api', 'activa' FROM organismo o, unnest(ARRAY['empresas', 'centros', 'sso']::integracion_tipo[]) t
WHERE o.nombre = 'Mutualidad A';
INSERT INTO integracion (empresa_id, tipo, protocolo, estado)
SELECT id, 'sso', 'oidc', 'activa' FROM empresa WHERE razon_social = 'Empresa 3';
CREATE TEMP TABLE t_int AS
SELECT i.id, coalesce(o.nombre, e.razon_social) AS dueno, i.tipo::text AS tipo
FROM integracion i LEFT JOIN organismo o ON o.id = i.organismo_id LEFT JOIN empresa e ON e.id = i.empresa_id;
GRANT SELECT ON t_int TO paritario_app;
INSERT INTO rol_externo (integracion_id, valor, rol_id)
SELECT t.id, x.v, x.r FROM t_int t, (VALUES ('ADMIN', 3), ('PREV', 4), ('AUD', 5)) x(v, r)
WHERE t.dueno = 'Mutualidad A' AND t.tipo = 'sso';
INSERT INTO rol_externo (integracion_id, valor, rol_id)
SELECT id, 'jefe', 3 FROM t_int WHERE dueno = 'Empresa 3';
GRANT EXECUTE ON FUNCTION importar_empresas(bigint, jsonb, text), importar_centros(bigint, jsonb, text),
    sincronizar_accesos_sso(bigint, text, uuid, text, text[]) TO paritario_app;

CREATE FUNCTION pg_temp.ultima(p_dueno text, p_tipo text) RETURNS sincronizacion
LANGUAGE sql AS $$
    SELECT s.* FROM sincronizacion s JOIN t_int t ON t.id = s.integracion_id
    WHERE t.dueno = p_dueno AND t.tipo = p_tipo ORDER BY s.id DESC LIMIT 1
$$;

SELECT pg_temp.debe_fallar('rol externo equivalente a un rol de organismo',
    $q$INSERT INTO rol_externo (integracion_id, valor, rol_id)
       SELECT id, 'SUPER', 1 FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'sso'$q$);
SELECT pg_temp.debe_fallar('empresa cliente con integración de listado de empresas',
    $q$INSERT INTO integracion (empresa_id, tipo, protocolo) SELECT id, 'empresas', 'api' FROM empresa WHERE razon_social = 'Empresa 3'$q$);
SELECT pg_temp.debe_fallar('acceso de origen sso sin integración',
    $q$INSERT INTO usuario_rol (usuario_id, rol_id, empresa_id, origen)
       SELECT u.id, 5, e.id, 'sso' FROM usuario u, empresa e WHERE u.rut = '15151515-0' AND e.razon_social = 'Empresa 1'$q$);

-- Las funciones las ejecuta la aplicación, sin sesión de usuario.
SET ROLE paritario_app;
SELECT pg_temp.debe_fallar('importar empresas con una integración de centros',
    $q$SELECT importar_empresas((SELECT id FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'centros'), '[{"contrato":"X"}]')$q$);
SELECT importar_empresas((SELECT id FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'empresas'),
    '[{"contrato": "A-1", "rut": "76.100.200-7", "razon_social": "Empresa 1"},
      {"contrato": "A-2", "rut": "76200300-7",   "razon_social": "Empresa 2"},
      {"contrato": "A-9", "rut": "77777777-7",   "razon_social": "Empresa Nueva"}]');
RESET ROLE;
SELECT pg_temp.verificar('empresas: 1 nueva y 2 existentes con contrato',
    (SELECT (nuevos * 10 + actualizados)::bigint FROM pg_temp.ultima('Mutualidad A', 'empresas')), 12);
SELECT pg_temp.verificar('empresas: la nueva queda en el organismo con su contrato',
    (SELECT count(*) FROM empresa e JOIN organismo o ON o.id = e.organismo_id
     WHERE e.rut = '77777777-7' AND e.codigo_contrato = 'A-9' AND o.nombre = 'Mutualidad A'), 1);

SET ROLE paritario_app;
SELECT importar_empresas((SELECT id FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'empresas'),
    '[{"contrato": "A-1", "rut": "76100200-7", "razon_social": "Empresa 1"},
      {"contrato": "A-2", "rut": "76200300-7", "razon_social": "Empresa 2"}]');
RESET ROLE;
SELECT pg_temp.verificar('empresas: sin cambios no cuenta actualizaciones y el contrato ausente queda de baja',
    (SELECT (actualizados * 10 + bajas)::bigint FROM pg_temp.ultima('Mutualidad A', 'empresas')), 1);
SELECT pg_temp.verificar('empresas: la baja no se borra',
    (SELECT count(*) FROM empresa WHERE rut = '77777777-7' AND estado = 'baja'), 1);

SET ROLE paritario_app;
SELECT importar_empresas((SELECT id FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'empresas'),
    '[{"contrato": "A-1", "rut": "76100200-7", "razon_social": "Empresa 1"},
      {"contrato": "A-3", "rut": "76300400-7", "razon_social": "Empresa 3"}]');
RESET ROLE;
SELECT pg_temp.verificar('empresas: no se apropia de un cliente directo y no aplica bajas con muchos errores',
    (SELECT (errores * 10 + bajas)::bigint FROM pg_temp.ultima('Mutualidad A', 'empresas')), 10);
SELECT pg_temp.verificar('empresas: Empresa 3 sigue siendo cliente directo y Empresa 2 sigue activa',
    (SELECT count(*) FROM empresa WHERE (razon_social = 'Empresa 3' AND organismo_id IS NULL)
                                     OR (razon_social = 'Empresa 2' AND estado = 'activo')), 2);

SET ROLE paritario_app;
SELECT importar_centros((SELECT id FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'centros'),
    '[{"contrato": "A-1", "codigo": "CT-1", "nombre": "Planta",  "comuna": "13101", "trabajadores": 50},
      {"contrato": "A-1", "codigo": "CT-2", "nombre": "Bodega",  "comuna": "2101"},
      {"contrato": "ZZ",  "codigo": "CT-9", "nombre": "Ajeno"}]');
RESET ROLE;
SELECT pg_temp.verificar('centros: 2 nuevos y el contrato desconocido como error',
    (SELECT (nuevos * 10 + errores)::bigint FROM pg_temp.ultima('Mutualidad A', 'centros')), 21);
SELECT pg_temp.verificar('centros: quedan en Empresa 1 con su comuna',
    (SELECT count(*) FROM sucursal s JOIN empresa e ON e.id = s.empresa_id JOIN comuna c ON c.id = s.comuna_id
     WHERE e.razon_social = 'Empresa 1' AND s.codigo_externo IN ('CT-1', 'CT-2') AND c.codigo IN ('13101', '02101')), 2);

-- SSO del organismo: rol PREV (coordinador) en dos contratos.
SET ROLE paritario_app;
SELECT sincronizar_accesos_sso((SELECT id FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'sso'),
    '19.191.919-k', '00000000-0000-0000-0000-000000000001', 'PREV', ARRAY['A-1', 'A-2']);
RESET ROLE;
SELECT pg_temp.verificar('sso: crea el usuario activo con dos accesos de coordinador',
    (SELECT count(*) FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id
     WHERE u.rut = '19191919-K' AND u.estado = 'activo' AND ur.vigente AND ur.rol_id = 4 AND ur.origen = 'sso'), 2);

-- En el siguiente ingreso el SSO trae otro rol y un solo contrato.
SET ROLE paritario_app;
SELECT sincronizar_accesos_sso((SELECT id FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'sso'),
    '19191919-K', '00000000-0000-0000-0000-000000000001', 'AUD', ARRAY['A-1', 'NO-EXISTE']);
RESET ROLE;
SELECT pg_temp.verificar('sso: revoca lo anterior y deja solo auditor en Empresa 1',
    (SELECT count(*) FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id JOIN empresa e ON e.id = ur.empresa_id
     WHERE u.rut = '19191919-K' AND ur.vigente), 1);
SELECT pg_temp.verificar('sso: el acceso vigente es auditor de Empresa 1',
    (SELECT count(*) FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id JOIN empresa e ON e.id = ur.empresa_id
     WHERE u.rut = '19191919-K' AND ur.vigente AND ur.rol_id = 5 AND e.razon_social = 'Empresa 1'), 1);
SELECT set_config('app.usuario_id', (SELECT id::text FROM usuario WHERE rut = '19191919-K'), true);
SET ROLE paritario_app;
SELECT pg_temp.verificar('sso: con ese acceso solo ve Empresa 1', (SELECT count(*) FROM empresa), 1);
RESET ROLE;
SELECT set_config('app.usuario_id', '', true);

-- Un rol externo desconocido revoca los accesos sso, pero no los asignados a mano.
SET ROLE paritario_app;
SELECT sincronizar_accesos_sso((SELECT id FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'sso'),
    '15151515-0', '00000000-0000-0000-0000-000000000002', 'DESCONOCIDO', ARRAY['A-1']);
RESET ROLE;
SELECT pg_temp.verificar('sso: el acceso manual del administrador de Empresa 1 se mantiene',
    (SELECT count(*) FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id
     WHERE u.rut = '15151515-0' AND ur.vigente AND ur.origen = 'manual'), 1);

-- SSO de una empresa cliente: el contrato se ignora, solo da acceso a esa empresa.
SET ROLE paritario_app;
SELECT sincronizar_accesos_sso((SELECT id FROM t_int WHERE dueno = 'Empresa 3'),
    '13131313-6', '00000000-0000-0000-0000-000000000003', 'jefe', ARRAY['A-1']);
RESET ROLE;
SELECT pg_temp.verificar('sso de empresa: administrador solo de Empresa 3',
    (SELECT count(*) FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id JOIN empresa e ON e.id = ur.empresa_id
     WHERE u.rut = '13131313-6' AND ur.vigente AND ur.rol_id = 3 AND e.razon_social = 'Empresa 3'), 1);
SELECT pg_temp.verificar('sso de empresa: ningún acceso fuera de Empresa 3',
    (SELECT count(*) FROM usuario u JOIN usuario_rol ur ON ur.usuario_id = u.id JOIN empresa e ON e.id = ur.empresa_id
     WHERE u.rut = '13131313-6' AND ur.vigente AND e.razon_social <> 'Empresa 3'), 0);

UPDATE usuario SET estado = 'bloqueado' WHERE rut = '16161616-8';
SET ROLE paritario_app;
SELECT pg_temp.debe_fallar('ingreso por SSO de una cuenta bloqueada',
    $q$SELECT sincronizar_accesos_sso((SELECT id FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'sso'),
       '16161616-8', '00000000-0000-0000-0000-000000000004', 'PREV', ARRAY['A-1'])$q$);
SELECT pg_temp.debe_fallar('mismo RUT con otra cuenta de Cognito',
    $q$SELECT sincronizar_accesos_sso((SELECT id FROM t_int WHERE dueno = 'Mutualidad A' AND tipo = 'sso'),
       '19191919-K', '00000000-0000-0000-0000-000000000009', 'PREV', ARRAY['A-1'])$q$);
RESET ROLE;

\echo 'Todas las verificaciones pasaron.'
ROLLBACK;
