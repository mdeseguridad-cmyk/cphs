-- =============================================================================
-- Paritario — esquema de base de datos (PostgreSQL 16)
-- Modelo de datos v5: 30 tablas en 5 dominios.
--
--   01 Organización ........... organismo, integracion_organismo, empresa,
--                               sucursal, region, comuna
--   02 Comité e integrantes ... comite, persona, comite_integrante, comision,
--                               comision_integrante
--   03 Programa y cumplimiento  programa_plantilla, actividad_tipo, actividad,
--                               material_apoyo, actividad_material, reunion,
--                               reunion_asistencia, documento,
--                               nivel_certificacion, auditoria
--   04 Seguridad y acceso ..... usuario, rol, usuario_rol, solicitud_acceso,
--                               log_acceso
--   05 Cumplimiento (21.719) .. solicitud_derecho_titular, politica_retencion,
--                               registro_incidente, encargado_tratamiento
--
-- Aislamiento: Row-Level Security en dos niveles (empresa y organismo).
-- La aplicación se conecta con un rol sin privilegios de dueño y, en cada
-- transacción, fija el usuario autenticado:
--
--     SET LOCAL app.usuario_id = '123';
--
-- Ejecutar con un rol dueño (que crea las tablas). Idempotente solo en una
-- base vacía: está pensado para la primera instalación, no como migración.
-- =============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS paritario;
SET search_path = paritario, public;

-- -----------------------------------------------------------------------------
-- Tipos enumerados
-- -----------------------------------------------------------------------------
CREATE TYPE organismo_tipo            AS ENUM ('mutualidad', 'servicio_publico', 'otro');
CREATE TYPE organismo_estado          AS ENUM ('activo', 'en_implementacion', 'baja');
CREATE TYPE integracion_tipo          AS ENUM ('sso', 'adherentes', 'certificacion', 'reportes');
CREATE TYPE integracion_estado        AS ENUM ('en_prueba', 'activa', 'inactiva');
CREATE TYPE organismo_administrador   AS ENUM ('achs', 'mutual_de_seguridad', 'ist', 'isl');
CREATE TYPE empresa_estado            AS ENUM ('activo', 'suspendido', 'baja');
CREATE TYPE sucursal_estado           AS ENUM ('vigente', 'no_vigente');
CREATE TYPE comite_estado             AS ENUM ('activo', 'baja');
CREATE TYPE integrante_tipo           AS ENUM ('titular', 'suplente');
CREATE TYPE representacion            AS ENUM ('empresa', 'trabajadores');
CREATE TYPE cargo_comite              AS ENUM ('presidente', 'secretario', 'integrante');
CREATE TYPE comision_tipo             AS ENUM ('investigacion_accidentes', 'capacitacion_difusion',
                                               'inspeccion_observacion', 'personalizada');
CREATE TYPE clasificacion_actividad   AS ENUM ('obligatoria_ley', 'recomendada');
CREATE TYPE frecuencia                AS ENUM ('quincenal', 'mensual', 'trimestral', 'semestral',
                                               'anual', 'unica', 'segun_evento');
CREATE TYPE actividad_estado          AS ENUM ('planificado', 'en_ejecucion', 'cerrado');
CREATE TYPE material_tipo             AS ENUM ('video', 'guia', 'formato', 'otro');
CREATE TYPE reunion_estado            AS ENUM ('planificada', 'realizada', 'no_realizada');
CREATE TYPE documento_tipo            AS ENUM ('constitucion', 'reunion', 'disolucion', 'capacitacion',
                                               'investigacion', 'informe_auditoria', 'otro');
CREATE TYPE auditoria_estado          AS ENUM ('pendiente', 'aprobada', 'rechazada');
CREATE TYPE usuario_estado            AS ENUM ('activo', 'bloqueado');
CREATE TYPE solicitud_estado          AS ENUM ('pendiente', 'aprobada', 'rechazada');
CREATE TYPE log_accion                AS ENUM ('login', 'ver', 'crear', 'editar', 'eliminar', 'exportar');
CREATE TYPE derecho_tipo              AS ENUM ('acceso', 'rectificacion', 'supresion', 'oposicion', 'portabilidad');
CREATE TYPE derecho_estado            AS ENUM ('recibida', 'en_proceso', 'respondida', 'rechazada');
CREATE TYPE retencion_accion          AS ENUM ('anonimizar', 'eliminar', 'conservar_legal');
CREATE TYPE incidente_severidad       AS ENUM ('baja', 'media', 'alta', 'critica');
CREATE TYPE incidente_estado          AS ENUM ('abierto', 'contenido', 'cerrado');
CREATE TYPE encargado_tipo            AS ENUM ('nube', 'proveedor', 'subencargado');

-- -----------------------------------------------------------------------------
-- Funciones de apoyo
-- -----------------------------------------------------------------------------

-- Valida un RUT chileno con dígito verificador (módulo 11).
-- Formato normalizado esperado: sin puntos, con guion y K mayúscula: 12345678-5
CREATE FUNCTION rut_valido(rut text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    cuerpo text;
    dv     text;
    suma   int := 0;
    mult   int := 2;
    resto  int;
    esperado text;
BEGIN
    IF rut !~ '^[0-9]{6,8}-[0-9K]$' THEN
        RETURN false;
    END IF;
    cuerpo := split_part(rut, '-', 1);
    dv     := split_part(rut, '-', 2);
    FOR i IN REVERSE length(cuerpo)..1 LOOP
        suma := suma + substr(cuerpo, i, 1)::int * mult;
        mult := CASE WHEN mult = 7 THEN 2 ELSE mult + 1 END;
    END LOOP;
    resto := 11 - (suma % 11);
    esperado := CASE resto WHEN 11 THEN '0' WHEN 10 THEN 'K' ELSE resto::text END;
    RETURN dv = esperado;
END;
$$;

CREATE DOMAIN rut AS varchar(10) CHECK (rut_valido(VALUE));

-- Mantiene updated_at al día.
CREATE FUNCTION tocar_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- =============================================================================
-- 01 · Organización
-- =============================================================================

CREATE TABLE organismo (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rut               rut          NOT NULL UNIQUE,
    nombre            varchar(200) NOT NULL,
    tipo              organismo_tipo NOT NULL,
    marca_nombre      varchar(120) NOT NULL,
    logo_key          varchar(300),
    color_primario    varchar(7)   CHECK (color_primario ~ '^#[0-9A-Fa-f]{6}$'),
    dominio           varchar(160) UNIQUE,
    correo_remitente  varchar(160),
    estado            organismo_estado NOT NULL DEFAULT 'en_implementacion',
    fecha_contrato    date
);
COMMENT ON TABLE organismo IS 'Organismo administrador que contrata la plataforma en marca blanca.';

CREATE TABLE integracion_organismo (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organismo_id           bigint NOT NULL REFERENCES organismo(id),
    tipo                   integracion_tipo NOT NULL,
    protocolo              varchar(30) NOT NULL,
    configuracion          jsonb NOT NULL DEFAULT '{}'::jsonb,
    estado                 integracion_estado NOT NULL DEFAULT 'en_prueba',
    ultima_sincronizacion  timestamptz,
    UNIQUE (organismo_id, tipo)
);
COMMENT ON TABLE  integracion_organismo IS 'Conexión con sistemas del organismo (SSO, adherentes, certificación, reportes).';
COMMENT ON COLUMN integracion_organismo.configuracion IS 'Parámetros sin secretos. Los secretos van en la bóveda (Secrets Manager).';

CREATE TABLE region (
    id      smallint PRIMARY KEY,
    codigo  char(2) GENERATED ALWAYS AS (lpad(id::text, 2, '0')) STORED,
    nombre  varchar(60) NOT NULL UNIQUE,
    orden   smallint    NOT NULL UNIQUE
);
COMMENT ON TABLE  region IS 'Catálogo de regiones de Chile. id = número oficial de la región.';
COMMENT ON COLUMN region.codigo IS 'Código en el formato oficial: 2 dígitos con cero inicial (01).';
COMMENT ON COLUMN region.orden IS 'Orden geográfico de norte a sur.';

CREATE TABLE comuna (
    id         int PRIMARY KEY,
    codigo     char(5) GENERATED ALWAYS AS (lpad(id::text, 5, '0')) STORED,
    region_id  smallint NOT NULL REFERENCES region(id),
    nombre     varchar(90) NOT NULL,
    UNIQUE (region_id, nombre),
    -- Los dos primeros dígitos del código territorial son los de la región.
    CHECK (id / 1000 = region_id)
);
COMMENT ON TABLE  comuna IS 'Catálogo de comunas. id = código único territorial (CUT) vigente.';
COMMENT ON COLUMN comuna.codigo IS 'Código en el formato oficial de la SUBDERE: 5 dígitos con cero inicial (01101).';

CREATE TABLE empresa (
    id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rut                      rut          NOT NULL UNIQUE,
    razon_social             varchar(200) NOT NULL,
    nombre_fantasia          varchar(200),
    rubro                    varchar(120),
    organismo_id             bigint REFERENCES organismo(id),
    organismo_administrador  organismo_administrador,
    plan                     varchar(40),
    estado                   empresa_estado NOT NULL DEFAULT 'activo',
    fecha_alta               date NOT NULL DEFAULT current_date,
    created_at               timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  empresa IS 'Empresa cliente de la plataforma (tenant).';
COMMENT ON COLUMN empresa.organismo_id IS 'Organismo que la entrega en marca blanca; nulo si es cliente directo.';
COMMENT ON COLUMN empresa.organismo_administrador IS 'Mutualidad u organismo al que está adherida (informativo).';
CREATE INDEX empresa_organismo_idx ON empresa (organismo_id);

CREATE TABLE sucursal (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    empresa_id         bigint NOT NULL REFERENCES empresa(id),
    alias              varchar(120),
    nombre             varchar(160) NOT NULL,
    direccion_calle    varchar(160),
    direccion_numero   varchar(20),
    comuna_id          int REFERENCES comuna(id),
    masa_trabajadores  int CHECK (masa_trabajadores >= 0),
    estado             sucursal_estado NOT NULL DEFAULT 'vigente'
);
COMMENT ON TABLE sucursal IS 'Centro de trabajo donde se constituye un comité.';
CREATE INDEX sucursal_empresa_idx ON sucursal (empresa_id);

-- =============================================================================
-- 02 · Comité, integrantes y comisiones
-- =============================================================================

CREATE TABLE comite (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    empresa_id          bigint NOT NULL REFERENCES empresa(id),
    sucursal_id         bigint REFERENCES sucursal(id),
    nombre              varchar(180) NOT NULL,
    estado              comite_estado NOT NULL DEFAULT 'activo',
    fecha_constitucion  date,
    fecha_disolucion    date,
    periodo_inicio      date,
    periodo_fin         date,
    n_titulares         smallint NOT NULL DEFAULT 3 CHECK (n_titulares > 0),
    n_suplentes         smallint NOT NULL DEFAULT 3 CHECK (n_suplentes >= 0),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CHECK (periodo_fin IS NULL OR periodo_inicio IS NULL OR periodo_fin > periodo_inicio),
    CHECK (estado <> 'baja' OR fecha_disolucion IS NOT NULL)
);
COMMENT ON TABLE  comite IS 'Comité Paritario de Higiene y Seguridad. La baja se marca con estado y fecha; nunca se borra.';
COMMENT ON COLUMN comite.n_titulares IS 'Titulares por cada parte (empresa y trabajadores).';
CREATE INDEX comite_empresa_idx ON comite (empresa_id);
CREATE TRIGGER comite_updated_at BEFORE UPDATE ON comite
    FOR EACH ROW EXECUTE FUNCTION tocar_updated_at();

CREATE TABLE persona (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rut         rut          NOT NULL UNIQUE,
    nombres     varchar(120) NOT NULL,
    apellidos   varchar(120) NOT NULL,
    email       varchar(160),
    telefono    varchar(30),
    created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE persona IS 'Dato maestro de una persona (trabajador). Una persona puede integrar varios comités.';

CREATE TABLE comite_integrante (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    comite_id       bigint NOT NULL REFERENCES comite(id),
    persona_id      bigint NOT NULL REFERENCES persona(id),
    tipo            integrante_tipo NOT NULL,
    representacion  representacion  NOT NULL,
    cargo           cargo_comite    NOT NULL DEFAULT 'integrante',
    es_aforado      boolean NOT NULL DEFAULT false,
    fecha_fuero     date,
    fecha_inicio    date NOT NULL DEFAULT current_date,
    fecha_termino   date,
    vigente         boolean NOT NULL DEFAULT true,
    CHECK (fecha_termino IS NULL OR fecha_termino >= fecha_inicio),
    CHECK (es_aforado OR fecha_fuero IS NULL),
    -- El fuero corresponde a un titular de los trabajadores.
    CHECK (NOT es_aforado OR (tipo = 'titular' AND representacion = 'trabajadores'))
);
COMMENT ON TABLE comite_integrante IS 'Participación de una persona en un comité y periodo.';
CREATE INDEX comite_integrante_comite_idx  ON comite_integrante (comite_id);
CREATE INDEX comite_integrante_persona_idx ON comite_integrante (persona_id);
-- Una persona no puede estar dos veces vigente en el mismo comité.
CREATE UNIQUE INDEX comite_integrante_persona_vigente_uq
    ON comite_integrante (comite_id, persona_id) WHERE vigente;
-- Un solo presidente, un solo secretario y un solo aforado vigentes por comité.
CREATE UNIQUE INDEX comite_presidente_uq  ON comite_integrante (comite_id) WHERE vigente AND cargo = 'presidente';
CREATE UNIQUE INDEX comite_secretario_uq  ON comite_integrante (comite_id) WHERE vigente AND cargo = 'secretario';
CREATE UNIQUE INDEX comite_aforado_uq     ON comite_integrante (comite_id) WHERE vigente AND es_aforado;

CREATE TABLE comision (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    comite_id   bigint NOT NULL REFERENCES comite(id),
    tipo        comision_tipo NOT NULL,
    nombre      varchar(160),
    created_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (tipo <> 'personalizada' OR nombre IS NOT NULL)
);
COMMENT ON TABLE comision IS 'Comisión de trabajo del comité.';
CREATE INDEX comision_comite_idx ON comision (comite_id);

CREATE TABLE comision_integrante (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    comision_id    bigint NOT NULL REFERENCES comision(id),
    integrante_id  bigint NOT NULL REFERENCES comite_integrante(id),
    UNIQUE (comision_id, integrante_id)
);
COMMENT ON TABLE comision_integrante IS 'Integrantes asignados a una comisión.';

-- =============================================================================
-- 04 · Seguridad y acceso (antes del dominio 03: documento y auditoría
--      referencian a usuario)
-- =============================================================================

CREATE TABLE usuario (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    persona_id      bigint REFERENCES persona(id),
    rut             rut NOT NULL UNIQUE,
    password_hash   varchar(255),
    estado          usuario_estado NOT NULL DEFAULT 'activo',
    mfa_habilitado  boolean NOT NULL DEFAULT false,
    ultimo_acceso   timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  usuario IS 'Credencial de acceso. persona_id es nulo en cuentas de servicio.';
COMMENT ON COLUMN usuario.password_hash IS 'Nulo si la autenticación es delegada (Cognito / SSO).';

CREATE TABLE rol (
    id           smallint PRIMARY KEY,
    codigo       varchar(20) NOT NULL UNIQUE,
    nombre       varchar(80) NOT NULL,
    descripcion  varchar(200),
    es_de_organismo boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE  rol IS 'Rol funcional del sistema.';
COMMENT ON COLUMN rol.es_de_organismo IS 'true para roles con ámbito de organismo (marca blanca).';

CREATE TABLE usuario_rol (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id    bigint   NOT NULL REFERENCES usuario(id),
    rol_id        smallint NOT NULL REFERENCES rol(id),
    organismo_id  bigint REFERENCES organismo(id),
    empresa_id    bigint REFERENCES empresa(id),
    comite_id     bigint REFERENCES comite(id),
    vigente       boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    -- Exactamente un ámbito principal: organismo o empresa.
    CHECK (num_nonnulls(organismo_id, empresa_id) = 1),
    -- Un ámbito de comité siempre va dentro de una empresa.
    CHECK (comite_id IS NULL OR empresa_id IS NOT NULL)
);
COMMENT ON TABLE usuario_rol IS 'Asignación de rol CON ámbito: base del control de acceso y de la seguridad por fila.';
CREATE INDEX usuario_rol_usuario_idx ON usuario_rol (usuario_id) WHERE vigente;

-- Coherencia entre el rol y su ámbito, y entre el comité y la empresa.
CREATE FUNCTION validar_usuario_rol() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    de_organismo boolean;
BEGIN
    SELECT es_de_organismo INTO de_organismo FROM rol WHERE id = NEW.rol_id;
    IF de_organismo AND NEW.organismo_id IS NULL THEN
        RAISE EXCEPTION 'El rol % requiere un organismo como ámbito', NEW.rol_id;
    END IF;
    IF NOT de_organismo AND NEW.empresa_id IS NULL THEN
        RAISE EXCEPTION 'El rol % requiere una empresa como ámbito', NEW.rol_id;
    END IF;
    IF NEW.comite_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM comite WHERE id = NEW.comite_id AND empresa_id = NEW.empresa_id
    ) THEN
        RAISE EXCEPTION 'El comité % no pertenece a la empresa %', NEW.comite_id, NEW.empresa_id;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER usuario_rol_valida BEFORE INSERT OR UPDATE ON usuario_rol
    FOR EACH ROW EXECUTE FUNCTION validar_usuario_rol();

CREATE TABLE solicitud_acceso (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rut                rut NOT NULL,
    nombre             varchar(160) NOT NULL,
    email              varchar(160) NOT NULL,
    empresa_id         bigint   NOT NULL REFERENCES empresa(id),
    rol_solicitado_id  smallint NOT NULL REFERENCES rol(id),
    comite_id          bigint REFERENCES comite(id),
    estado             solicitud_estado NOT NULL DEFAULT 'pendiente',
    resuelta_por       bigint REFERENCES usuario(id),
    fecha_solicitud    timestamptz NOT NULL DEFAULT now(),
    fecha_resolucion   timestamptz,
    CHECK ((estado = 'pendiente') = (fecha_resolucion IS NULL))
);
COMMENT ON TABLE solicitud_acceso IS 'Autoservicio: registro de usuario pendiente de aprobación del administrador de empresa.';
CREATE INDEX solicitud_acceso_pendiente_idx ON solicitud_acceso (empresa_id) WHERE estado = 'pendiente';

CREATE TABLE log_acceso (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id  bigint REFERENCES usuario(id),
    accion      log_accion NOT NULL,
    entidad     varchar(60),
    entidad_id  bigint,
    ip          inet,
    user_agent  varchar(300),
    "timestamp" timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE log_acceso IS 'Bitácora de acceso a datos personales (Ley 21.719). Solo se inserta; nunca se modifica.';
CREATE INDEX log_acceso_usuario_idx ON log_acceso (usuario_id, "timestamp");
CREATE INDEX log_acceso_entidad_idx ON log_acceso (entidad, entidad_id);

-- =============================================================================
-- 03 · Programa de trabajo, cumplimiento y certificación
-- =============================================================================

CREATE TABLE programa_plantilla (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organismo_id   bigint REFERENCES organismo(id),
    rubro          varchar(120) NOT NULL,
    nombre         varchar(160) NOT NULL,
    ds_referencia  varchar(20) DEFAULT 'DS 44',
    descripcion    text,
    vigente        boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE  programa_plantilla IS 'Programa de trabajo propuesto según rubro.';
COMMENT ON COLUMN programa_plantilla.organismo_id IS 'Nulo = plantilla general de la plataforma.';

CREATE TABLE actividad_tipo (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plantilla_id   bigint NOT NULL REFERENCES programa_plantilla(id),
    titulo         varchar(200) NOT NULL,
    descripcion    text,
    clasificacion  clasificacion_actividad NOT NULL,
    frecuencia     frecuencia NOT NULL,
    comision_tipo  comision_tipo,
    niveles_cert   varchar(60)
);
COMMENT ON TABLE actividad_tipo IS 'Actividad predefinida dentro de una plantilla.';
CREATE INDEX actividad_tipo_plantilla_idx ON actividad_tipo (plantilla_id);

CREATE TABLE material_apoyo (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organismo_id  bigint REFERENCES organismo(id),
    tipo          material_tipo NOT NULL,
    titulo        varchar(200) NOT NULL,
    archivo_key   varchar(300),
    url           varchar(300),
    rubro         varchar(120),
    descripcion   text,
    CHECK (num_nonnulls(archivo_key, url) >= 1)
);
COMMENT ON TABLE  material_apoyo IS 'Biblioteca de material (videos, guías, formatos).';
COMMENT ON COLUMN material_apoyo.organismo_id IS 'Nulo = material general de la plataforma.';

CREATE TABLE actividad_material (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actividad_tipo_id  bigint NOT NULL REFERENCES actividad_tipo(id),
    material_id        bigint NOT NULL REFERENCES material_apoyo(id),
    UNIQUE (actividad_tipo_id, material_id)
);
COMMENT ON TABLE actividad_material IS 'Material sugerido para una actividad tipo.';

CREATE TABLE documento (
    id                        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    comite_id                 bigint NOT NULL REFERENCES comite(id),
    tipo                      documento_tipo NOT NULL,
    nombre                    varchar(200) NOT NULL,
    archivo_key               varchar(300) NOT NULL,
    mime                      varchar(80),
    tamano_bytes              bigint CHECK (tamano_bytes >= 0),
    fecha_documento           date,
    fecha_carga               timestamptz NOT NULL DEFAULT now(),
    contiene_datos_sensibles  boolean NOT NULL DEFAULT false,
    vigente                   boolean NOT NULL DEFAULT true,
    cargado_por               bigint REFERENCES usuario(id)
);
COMMENT ON TABLE  documento IS 'Acta, certificado u otro archivo del comité. El binario vive en S3; aquí solo su ruta.';
COMMENT ON COLUMN documento.contiene_datos_sensibles IS 'Datos de salud (investigación de accidentes y enfermedades): acceso reforzado.';
CREATE INDEX documento_comite_idx ON documento (comite_id);

CREATE TABLE actividad (
    id                         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    comite_id                  bigint NOT NULL REFERENCES comite(id),
    actividad_tipo_id          bigint REFERENCES actividad_tipo(id),
    actividad_padre_id         bigint REFERENCES actividad(id),
    comision_id                bigint REFERENCES comision(id),
    responsable_integrante_id  bigint REFERENCES comite_integrante(id),
    titulo                     varchar(200) NOT NULL,
    descripcion                text,
    clasificacion              clasificacion_actividad NOT NULL DEFAULT 'recomendada',
    frecuencia                 frecuencia,
    estado                     actividad_estado NOT NULL DEFAULT 'planificado',
    fecha_planificada          date,
    fecha_cierre               date,
    evidencia_documento_id     bigint REFERENCES documento(id),
    CHECK (actividad_padre_id IS NULL OR actividad_padre_id <> id),
    CHECK ((estado = 'cerrado') = (fecha_cierre IS NOT NULL))
);
COMMENT ON TABLE  actividad IS 'Actividad del programa de un comité (flujo Kanban: planificado, en ejecución, cerrado).';
COMMENT ON COLUMN actividad.actividad_tipo_id IS 'Nulo si la actividad se creó manualmente.';
CREATE INDEX actividad_comite_idx ON actividad (comite_id, estado);

CREATE TABLE reunion (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    comite_id          bigint   NOT NULL REFERENCES comite(id),
    anio               smallint NOT NULL CHECK (anio BETWEEN 2000 AND 2100),
    mes                smallint NOT NULL CHECK (mes BETWEEN 1 AND 12),
    numero             smallint NOT NULL CHECK (numero > 0),
    fecha_programada   date,
    fecha_realizada    date,
    estado             reunion_estado NOT NULL DEFAULT 'planificada',
    acta_documento_id  bigint REFERENCES documento(id),
    observacion        text,
    UNIQUE (comite_id, anio, numero),
    CHECK ((estado = 'realizada') = (fecha_realizada IS NOT NULL))
);
COMMENT ON TABLE reunion IS 'Reunión del comité. El DS 44 exige al menos una reunión mensual con acta.';
CREATE INDEX reunion_comite_periodo_idx ON reunion (comite_id, anio, mes);

CREATE TABLE reunion_asistencia (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reunion_id     bigint NOT NULL REFERENCES reunion(id),
    integrante_id  bigint NOT NULL REFERENCES comite_integrante(id),
    presente       boolean NOT NULL,
    justificacion  varchar(200),
    UNIQUE (reunion_id, integrante_id)
);
COMMENT ON TABLE reunion_asistencia IS 'Asistencia de cada integrante a una reunión.';

CREATE TABLE nivel_certificacion (
    id            smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organismo_id  bigint REFERENCES organismo(id),
    codigo        varchar(20) NOT NULL,
    nombre        varchar(80) NOT NULL,
    puntaje_min   numeric(5,2),
    criterios     text,
    UNIQUE NULLS NOT DISTINCT (organismo_id, codigo)
);
COMMENT ON TABLE  nivel_certificacion IS 'Niveles de certificación. Cada organismo puede definir su propio programa.';
COMMENT ON COLUMN nivel_certificacion.organismo_id IS 'Nulo = niveles generales de la plataforma.';

CREATE TABLE auditoria (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    comite_id               bigint NOT NULL REFERENCES comite(id),
    auditor_usuario_id      bigint REFERENCES usuario(id),
    fecha_auditoria         date NOT NULL,
    nivel_certificacion_id  smallint REFERENCES nivel_certificacion(id),
    puntaje                 numeric(5,2),
    estado                  auditoria_estado NOT NULL DEFAULT 'pendiente',
    informe_key             varchar(300),
    proxima_revision        date,
    CHECK (proxima_revision IS NULL OR proxima_revision > fecha_auditoria)
);
COMMENT ON TABLE auditoria IS 'Auditoría de certificación del comité.';
CREATE INDEX auditoria_comite_idx ON auditoria (comite_id, fecha_auditoria DESC);

-- =============================================================================
-- 05 · Cumplimiento y privacidad (Ley 21.719)
-- =============================================================================

CREATE TABLE solicitud_derecho_titular (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    persona_id       bigint NOT NULL REFERENCES persona(id),
    tipo             derecho_tipo   NOT NULL,
    estado           derecho_estado NOT NULL DEFAULT 'recibida',
    canal            varchar(60),
    fecha_solicitud  timestamptz NOT NULL DEFAULT now(),
    fecha_respuesta  timestamptz,
    resuelta_por     bigint REFERENCES usuario(id),
    observacion      text,
    CHECK (fecha_respuesta IS NULL OR fecha_respuesta >= fecha_solicitud)
);
COMMENT ON TABLE solicitud_derecho_titular IS 'Ejercicio de derechos ARCOP (acceso, rectificación, supresión, oposición, portabilidad).';

CREATE TABLE politica_retencion (
    id                smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entidad           varchar(60) NOT NULL UNIQUE,
    descripcion       varchar(200),
    periodo_meses     int NOT NULL CHECK (periodo_meses >= 0),
    accion_al_vencer  retencion_accion NOT NULL,
    base_legal        varchar(160)
);
COMMENT ON TABLE  politica_retencion IS 'Plazo de conservación por tipo de dato o documento.';
COMMENT ON COLUMN politica_retencion.periodo_meses IS '0 = conservación legal indefinida.';

CREATE TABLE registro_incidente (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha_deteccion       timestamptz NOT NULL DEFAULT now(),
    descripcion           text NOT NULL,
    datos_afectados       varchar(200),
    n_titulares           int CHECK (n_titulares >= 0),
    severidad             incidente_severidad NOT NULL,
    notificado_agencia    boolean NOT NULL DEFAULT false,
    fecha_notif_agencia   timestamptz,
    notificado_titulares  boolean NOT NULL DEFAULT false,
    estado                incidente_estado NOT NULL DEFAULT 'abierto',
    responsable_id        bigint REFERENCES usuario(id),
    CHECK (notificado_agencia = (fecha_notif_agencia IS NOT NULL))
);
COMMENT ON TABLE registro_incidente IS 'Brechas de seguridad y su notificación a la Agencia y a los titulares.';

CREATE TABLE encargado_tratamiento (
    id                           smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre                       varchar(160) NOT NULL,
    tipo                         encargado_tipo NOT NULL,
    pais                         varchar(60) NOT NULL,
    contrato_dpa                 boolean NOT NULL DEFAULT false,
    transferencia_internacional  boolean NOT NULL DEFAULT false,
    salvaguarda                  varchar(160),
    vigente                      boolean NOT NULL DEFAULT true,
    CHECK (NOT transferencia_internacional OR salvaguarda IS NOT NULL)
);
COMMENT ON TABLE encargado_tratamiento IS 'Subencargados que tratan datos por cuenta del proveedor (p. ej. la nube).';

-- =============================================================================
-- Seguridad por fila (Row-Level Security)
--
-- La aplicación fija app.usuario_id en cada transacción. Las funciones de
-- ámbito calculan qué ve ese usuario:
--   - comites_visibles(): para indicadores. Incluye los comités de las
--     empresas de su organismo (rol de organismo).
--   - comites_con_detalle(): para datos de personas y documentos. Excluye el
--     ámbito de organismo: el organismo ve indicadores agregados, no personas.
-- Las funciones son SECURITY DEFINER para leer usuario_rol sin quedar
-- atrapadas en las mismas políticas.
-- =============================================================================

CREATE FUNCTION usuario_actual() RETURNS bigint
LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('app.usuario_id', true), '')::bigint
$$;

CREATE FUNCTION organismos_visibles() RETURNS bigint[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = paritario, pg_temp AS $$
    SELECT coalesce(array_agg(DISTINCT ur.organismo_id), '{}')
    FROM usuario_rol ur
    WHERE ur.usuario_id = usuario_actual() AND ur.vigente AND ur.organismo_id IS NOT NULL
$$;

CREATE FUNCTION empresas_visibles() RETURNS bigint[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = paritario, pg_temp AS $$
    SELECT coalesce(array_agg(DISTINCT e.id), '{}')
    FROM usuario_rol ur
    JOIN empresa e
      ON e.id = ur.empresa_id
      OR (ur.organismo_id IS NOT NULL AND e.organismo_id = ur.organismo_id)
    WHERE ur.usuario_id = usuario_actual() AND ur.vigente
$$;

CREATE FUNCTION comites_visibles() RETURNS bigint[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = paritario, pg_temp AS $$
    SELECT coalesce(array_agg(DISTINCT c.id), '{}')
    FROM usuario_rol ur
    JOIN comite c
      ON c.id = ur.comite_id
      OR (ur.comite_id IS NULL AND c.empresa_id = ur.empresa_id)
      OR (ur.organismo_id IS NOT NULL
          AND c.empresa_id IN (SELECT id FROM empresa WHERE organismo_id = ur.organismo_id))
    WHERE ur.usuario_id = usuario_actual() AND ur.vigente
$$;

CREATE FUNCTION comites_con_detalle() RETURNS bigint[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = paritario, pg_temp AS $$
    SELECT coalesce(array_agg(DISTINCT c.id), '{}')
    FROM usuario_rol ur
    JOIN comite c
      ON c.id = ur.comite_id
      OR (ur.comite_id IS NULL AND c.empresa_id = ur.empresa_id)
    WHERE ur.usuario_id = usuario_actual() AND ur.vigente AND ur.empresa_id IS NOT NULL
$$;

CREATE FUNCTION personas_con_detalle() RETURNS bigint[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = paritario, pg_temp AS $$
    SELECT coalesce(array_agg(DISTINCT ci.persona_id), '{}')
    FROM comite_integrante ci
    WHERE ci.comite_id = ANY (comites_con_detalle())
$$;

-- Organismo: lo ven sus administradores y las empresas que lo usan (para la marca).
ALTER TABLE organismo ENABLE ROW LEVEL SECURITY;
CREATE POLICY organismo_ambito ON organismo
    USING (id = ANY (organismos_visibles())
           OR id IN (SELECT organismo_id FROM empresa));

ALTER TABLE integracion_organismo ENABLE ROW LEVEL SECURITY;
CREATE POLICY integracion_ambito ON integracion_organismo
    USING (organismo_id = ANY (organismos_visibles()));

ALTER TABLE empresa ENABLE ROW LEVEL SECURITY;
CREATE POLICY empresa_ambito ON empresa
    USING (id = ANY (empresas_visibles()));

ALTER TABLE sucursal ENABLE ROW LEVEL SECURITY;
CREATE POLICY sucursal_ambito ON sucursal
    USING (empresa_id = ANY (empresas_visibles()));

ALTER TABLE comite ENABLE ROW LEVEL SECURITY;
CREATE POLICY comite_ambito ON comite
    USING (id = ANY (comites_visibles()))
    WITH CHECK (empresa_id = ANY (empresas_visibles()));  -- permite crear comités nuevos

-- Tablas con datos de personas: solo con ámbito de empresa o comité.
ALTER TABLE persona ENABLE ROW LEVEL SECURITY;
CREATE POLICY persona_ambito ON persona
    USING (id = ANY (personas_con_detalle())
           OR id = (SELECT persona_id FROM usuario WHERE id = usuario_actual()))
    WITH CHECK (true);  -- se puede registrar una persona nueva antes de vincularla

ALTER TABLE comite_integrante ENABLE ROW LEVEL SECURITY;
CREATE POLICY comite_integrante_ambito ON comite_integrante
    USING (comite_id = ANY (comites_con_detalle()));

ALTER TABLE comision_integrante ENABLE ROW LEVEL SECURITY;
CREATE POLICY comision_integrante_ambito ON comision_integrante
    USING (comision_id IN (SELECT id FROM comision WHERE comite_id = ANY (comites_con_detalle())));

ALTER TABLE reunion_asistencia ENABLE ROW LEVEL SECURITY;
CREATE POLICY reunion_asistencia_ambito ON reunion_asistencia
    USING (reunion_id IN (SELECT id FROM reunion WHERE comite_id = ANY (comites_con_detalle())));

ALTER TABLE documento ENABLE ROW LEVEL SECURITY;
CREATE POLICY documento_ambito ON documento
    USING (comite_id = ANY (comites_con_detalle()));

-- Tablas de gestión del comité: visibles también para el organismo (indicadores).
ALTER TABLE comision ENABLE ROW LEVEL SECURITY;
CREATE POLICY comision_ambito ON comision
    USING (comite_id = ANY (comites_visibles()));

ALTER TABLE actividad ENABLE ROW LEVEL SECURITY;
CREATE POLICY actividad_ambito ON actividad
    USING (comite_id = ANY (comites_visibles()));

ALTER TABLE reunion ENABLE ROW LEVEL SECURITY;
CREATE POLICY reunion_ambito ON reunion
    USING (comite_id = ANY (comites_visibles()));

ALTER TABLE auditoria ENABLE ROW LEVEL SECURITY;
CREATE POLICY auditoria_ambito ON auditoria
    USING (comite_id = ANY (comites_visibles()));

-- Contenido: el general (organismo nulo) lo ven todos; el de un organismo,
-- solo él y sus empresas.
ALTER TABLE programa_plantilla ENABLE ROW LEVEL SECURITY;
CREATE POLICY programa_plantilla_ambito ON programa_plantilla
    USING (organismo_id IS NULL
           OR organismo_id = ANY (organismos_visibles())
           OR organismo_id IN (SELECT organismo_id FROM empresa));

ALTER TABLE material_apoyo ENABLE ROW LEVEL SECURITY;
CREATE POLICY material_apoyo_ambito ON material_apoyo
    USING (organismo_id IS NULL
           OR organismo_id = ANY (organismos_visibles())
           OR organismo_id IN (SELECT organismo_id FROM empresa));

ALTER TABLE nivel_certificacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY nivel_certificacion_ambito ON nivel_certificacion
    USING (organismo_id IS NULL
           OR organismo_id = ANY (organismos_visibles())
           OR organismo_id IN (SELECT organismo_id FROM empresa));

ALTER TABLE solicitud_acceso ENABLE ROW LEVEL SECURITY;
CREATE POLICY solicitud_acceso_ambito ON solicitud_acceso
    USING (empresa_id = ANY (empresas_visibles()))
    WITH CHECK (true);  -- el autoservicio crea solicitudes sin sesión de empresa

-- =============================================================================
-- Vistas (security_invoker: respetan la seguridad por fila de quien consulta)
-- =============================================================================

-- Cumplimiento de reuniones por comité y año: realizadas sobre exigidas.
-- Exigidas = reuniones cuyo mes ya pasó o que ya se registraron como
-- realizadas o no realizadas.
CREATE VIEW v_cumplimiento_reuniones WITH (security_invoker = true) AS
SELECT
    r.comite_id,
    r.anio,
    count(*) FILTER (WHERE r.estado = 'realizada')                  AS realizadas,
    count(*) FILTER (WHERE r.estado = 'no_realizada')               AS no_realizadas,
    count(*) FILTER (WHERE r.estado <> 'planificada')               AS exigidas,
    count(*) FILTER (WHERE r.estado = 'realizada' AND r.acta_documento_id IS NULL) AS realizadas_sin_acta,
    round(100.0 * count(*) FILTER (WHERE r.estado = 'realizada')
          / nullif(count(*) FILTER (WHERE r.estado <> 'planificada'), 0), 1) AS porcentaje
FROM reunion r
GROUP BY r.comite_id, r.anio;

-- Paridad de cada comité: titulares y suplentes vigentes por representación.
CREATE VIEW v_paridad_comite WITH (security_invoker = true) AS
SELECT
    c.id AS comite_id,
    c.n_titulares,
    c.n_suplentes,
    count(*) FILTER (WHERE ci.tipo = 'titular'  AND ci.representacion = 'empresa')       AS titulares_empresa,
    count(*) FILTER (WHERE ci.tipo = 'titular'  AND ci.representacion = 'trabajadores')  AS titulares_trabajadores,
    count(*) FILTER (WHERE ci.tipo = 'suplente' AND ci.representacion = 'empresa')       AS suplentes_empresa,
    count(*) FILTER (WHERE ci.tipo = 'suplente' AND ci.representacion = 'trabajadores')  AS suplentes_trabajadores,
    (count(*) FILTER (WHERE ci.tipo = 'titular'  AND ci.representacion = 'empresa')      = c.n_titulares
     AND count(*) FILTER (WHERE ci.tipo = 'titular'  AND ci.representacion = 'trabajadores') = c.n_titulares
     AND count(*) FILTER (WHERE ci.tipo = 'suplente' AND ci.representacion = 'empresa')     = c.n_suplentes
     AND count(*) FILTER (WHERE ci.tipo = 'suplente' AND ci.representacion = 'trabajadores') = c.n_suplentes) AS es_paritario
FROM comite c
LEFT JOIN comite_integrante ci ON ci.comite_id = c.id AND ci.vigente
GROUP BY c.id, c.n_titulares, c.n_suplentes;

COMMIT;
