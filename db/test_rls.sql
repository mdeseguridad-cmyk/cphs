-- =============================================================================
-- Paritario — prueba de aislamiento (Row-Level Security) y reglas de negocio.
--
-- Uso, sobre una base de prueba vacía:
--   psql -v ON_ERROR_STOP=1 -f db/schema.sql -f db/seed.sql -f db/test_rls.sql
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
    ('17171717-5', 'Admin', 'Empresa 3');

INSERT INTO comite_integrante (comite_id, persona_id, tipo, representacion, cargo)
SELECT c.id, p.id, 'titular', 'trabajadores', 'presidente'
FROM (VALUES ('C1','11111111-1'), ('C3','12345678-5'), ('C4','13131313-6')) v(com, rut)
JOIN comite c ON c.nombre = v.com JOIN persona p ON p.rut = v.rut;

INSERT INTO reunion (comite_id, anio, mes, numero, estado, fecha_realizada)
SELECT c.id, 2026, 1, 1, 'realizada', '2026-01-15' FROM comite c;

INSERT INTO documento (comite_id, tipo, nombre, archivo_key, contiene_datos_sensibles)
SELECT c.id, 'investigacion', 'Investigación ' || c.nombre, 's3://doc/' || c.nombre, true FROM comite c;

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

-- Administrador de Empresa 1: ve su empresa, sus 2 comités y el detalle.
SELECT set_config('app.usuario_id', (SELECT id::text FROM t_usuarios WHERE rut = '15151515-0'), true);
SELECT pg_temp.verificar('empresa 1: empresas', (SELECT count(*) FROM empresa), 1);
SELECT pg_temp.verificar('empresa 1: comités', (SELECT count(*) FROM comite), 2);
SELECT pg_temp.verificar('empresa 1: integrantes', (SELECT count(*) FROM comite_integrante), 1);
SELECT pg_temp.verificar('empresa 1: documentos', (SELECT count(*) FROM documento), 2);
SELECT pg_temp.verificar('empresa 1: no ve la persona de Empresa 2', (SELECT count(*) FROM persona WHERE rut = '12345678-5'), 0);
SELECT pg_temp.verificar('empresa 1: ve la marca de su organismo', (SELECT count(*) FROM organismo), 1);
SELECT pg_temp.verificar('empresa 1: no ve integraciones del organismo', (SELECT count(*) FROM integracion_organismo), 0);

-- Coordinador de C1: solo su comité.
SELECT set_config('app.usuario_id', (SELECT id::text FROM t_usuarios WHERE rut = '16161616-8'), true);
SELECT pg_temp.verificar('coordinador C1: comités', (SELECT count(*) FROM comite), 1);
SELECT pg_temp.verificar('coordinador C1: documentos', (SELECT count(*) FROM documento), 1);

-- Administrador de Empresa 3 (cliente directo): nada de la Mutualidad A.
SELECT set_config('app.usuario_id', (SELECT id::text FROM t_usuarios WHERE rut = '17171717-5'), true);
SELECT pg_temp.verificar('empresa 3: empresas', (SELECT count(*) FROM empresa), 1);
SELECT pg_temp.verificar('empresa 3: comités', (SELECT count(*) FROM comite), 1);
SELECT pg_temp.verificar('empresa 3: organismos', (SELECT count(*) FROM organismo), 0);
SELECT pg_temp.verificar('empresa 3: no ve comités de otras empresas', (SELECT count(*) FROM comite WHERE nombre IN ('C1','C2','C3')), 0);
SELECT pg_temp.verificar('catálogo de organismos administradores visible para todos', (SELECT count(*) FROM organismo_administrador), 4);
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
SELECT pg_temp.debe_fallar('código SUSESO con formato inválido',
    $q$INSERT INTO organismo_administrador (id, sigla, nombre, tipo, codigo_suseso) VALUES (9, 'X', 'Prueba', 'otro', '31A1')$q$);
SELECT pg_temp.debe_fallar('transferencia internacional sin salvaguarda',
    $q$INSERT INTO encargado_tratamiento (nombre, tipo, pais, transferencia_internacional)
       VALUES ('Nube', 'nube', 'Brasil', true)$q$);

-- Vista de paridad: C1 tiene un solo titular de trabajadores, no es paritario.
SELECT pg_temp.verificar('paridad: C1 no es paritario',
    (SELECT count(*) FROM v_paridad_comite v JOIN comite c ON c.id = v.comite_id
     WHERE c.nombre = 'C1' AND NOT v.es_paritario), 1);

\echo 'Todas las verificaciones pasaron.'
ROLLBACK;
