-- =============================================================================
-- Paritario — esquema de base de datos (PostgreSQL 16)
-- Modelo de datos v5.6: 40 tablas en 5 dominios.
--
--   01 Organización ........... organismo_administrador, organismo, empresa,
--                               sucursal, integracion, rol_externo,
--                               sincronizacion, region, comuna,
--                               actividad_seccion, actividad_economica
--   02 Comité e integrantes ... comite, persona, comite_integrante, comision,
--                               comision_integrante
--   03 Programa y cumplimiento  programa_plantilla, actividad_tipo, actividad,
--                               material_apoyo, actividad_material, reunion,
--                               reunion_asistencia, documento,
--                               nivel_certificacion, auditoria,
--                               codigo_sisesat, equivalencia_cie10_oit,
--                               investigacion_accidente,
--                               investigacion_causa, investigacion_medida
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
CREATE TYPE integracion_tipo          AS ENUM ('sso', 'empresas', 'centros', 'certificacion', 'reportes');
CREATE TYPE sincronizacion_estado     AS ENUM ('correcta', 'con_errores', 'fallida');
CREATE TYPE acceso_origen             AS ENUM ('manual', 'solicitud', 'sso');
CREATE TYPE integracion_estado        AS ENUM ('en_prueba', 'activa', 'inactiva');
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
CREATE TYPE usuario_estado            AS ENUM ('invitado', 'activo', 'bloqueado');
CREATE TYPE documento_estado          AS ENUM ('pendiente', 'disponible');
CREATE TYPE solicitud_estado          AS ENUM ('pendiente', 'aprobada', 'rechazada');
CREATE TYPE log_accion                AS ENUM ('login', 'ver', 'crear', 'editar', 'eliminar', 'exportar');
CREATE TYPE derecho_tipo              AS ENUM ('acceso', 'rectificacion', 'supresion', 'oposicion', 'portabilidad');
CREATE TYPE derecho_estado            AS ENUM ('recibida', 'en_proceso', 'respondida', 'rechazada');
CREATE TYPE retencion_accion          AS ENUM ('anonimizar', 'eliminar', 'conservar_legal');
CREATE TYPE incidente_severidad       AS ENUM ('baja', 'media', 'alta', 'critica');
CREATE TYPE incidente_estado          AS ENUM ('abierto', 'contenido', 'cerrado');
CREATE TYPE encargado_tipo            AS ENUM ('nube', 'proveedor', 'subencargado');
CREATE TYPE sisesat_clasificacion     AS ENUM ('forma_accidente', 'agente_material', 'ubicacion_lesion',
                                               'causa_externa_cie10', 'lesion_cie10',
                                               'agente_enfermedad', 'enfermedad_cie10');
CREATE TYPE siniestro_tipo            AS ENUM ('accidente_trabajo', 'accidente_trayecto', 'enfermedad_profesional');
CREATE TYPE siniestro_gravedad        AS ENUM ('leve', 'grave', 'fatal');
CREATE TYPE investigacion_estado      AS ENUM ('abierta', 'en_analisis', 'cerrada');
CREATE TYPE causa_tipo                AS ENUM ('inmediata', 'basica');
CREATE TYPE jerarquia_control         AS ENUM ('eliminacion', 'sustitucion', 'control_ingenieria',
                                               'control_administrativo', 'proteccion_personal');
CREATE TYPE medida_estado             AS ENUM ('pendiente', 'en_ejecucion', 'implementada', 'verificada');

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

-- Organismos administradores del seguro de la Ley 16.744 (catálogo).
CREATE TABLE organismo_administrador (
    id             smallint PRIMARY KEY,
    sigla          varchar(10)  NOT NULL UNIQUE,
    nombre         varchar(120) NOT NULL UNIQUE,
    tipo           organismo_tipo NOT NULL,
    codigo_suseso  char(4) UNIQUE CHECK (codigo_suseso ~ '^[0-9]{4}$')
);
COMMENT ON TABLE  organismo_administrador IS 'Organismos administradores del seguro de la Ley 16.744 (mutualidades e ISL).';
COMMENT ON COLUMN organismo_administrador.codigo_suseso IS 'Código de identificación de la SUSESO (Compendio, remisión de antecedentes a la Dirección del Trabajo). Nulo si no tiene uno asignado.';

CREATE TABLE organismo (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rut               rut          NOT NULL UNIQUE,
    nombre            varchar(200) NOT NULL,
    tipo              organismo_tipo NOT NULL,
    organismo_administrador_id smallint REFERENCES organismo_administrador(id),
    marca_nombre      varchar(120) NOT NULL,
    logo_key          varchar(300),
    color_primario    varchar(7)   CHECK (color_primario ~ '^#[0-9A-Fa-f]{6}$'),
    dominio           varchar(160) UNIQUE,
    correo_remitente  varchar(160),
    estado            organismo_estado NOT NULL DEFAULT 'en_implementacion',
    fecha_contrato    date
);
COMMENT ON TABLE  organismo IS 'Organismo que contrata la plataforma en marca blanca.';
COMMENT ON COLUMN organismo.organismo_administrador_id IS 'Si el organismo contratante es un organismo administrador de la Ley 16.744, cuál es.';

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

-- Actividad económica: códigos del SII (6 dígitos) basados en el CIIU4.CL 2012.
-- La sección (A–U) es el "rubro" de la plataforma: define la plantilla de
-- programa de trabajo y el material de apoyo que se proponen a la empresa.
CREATE TABLE actividad_seccion (
    codigo  char(1) PRIMARY KEY CHECK (codigo ~ '^[A-U]$'),
    nombre  varchar(200) NOT NULL UNIQUE
);
COMMENT ON TABLE actividad_seccion IS 'Secciones del CIIU4.CL 2012 (A–U). Es el rubro de la empresa en la plataforma.';

CREATE TABLE actividad_economica (
    codigo       char(6) PRIMARY KEY CHECK (codigo ~ '^[0-9]{6}$'),
    seccion      char(1) NOT NULL REFERENCES actividad_seccion(codigo),
    grupo        varchar(200) NOT NULL,
    descripcion  varchar(300) NOT NULL
);
COMMENT ON TABLE  actividad_economica IS 'Códigos de actividad económica del SII (CIIU4.CL 2012, 6 dígitos).';
COMMENT ON COLUMN actividad_economica.grupo IS 'Agrupación con que el SII presenta los códigos.';
CREATE INDEX actividad_economica_seccion_idx ON actividad_economica (seccion);

CREATE TABLE empresa (
    id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rut                      rut          NOT NULL UNIQUE,
    razon_social             varchar(200) NOT NULL,
    nombre_fantasia          varchar(200),
    actividad_economica_codigo char(6) REFERENCES actividad_economica(codigo),
    organismo_id             bigint REFERENCES organismo(id),
    organismo_administrador_id smallint REFERENCES organismo_administrador(id),
    codigo_contrato          varchar(40),
    plan                     varchar(40),
    estado                   empresa_estado NOT NULL DEFAULT 'activo',
    fecha_alta               date NOT NULL DEFAULT current_date,
    created_at               timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  empresa IS 'Empresa cliente de la plataforma (tenant).';
COMMENT ON COLUMN empresa.actividad_economica_codigo IS 'Código de actividad económica principal ante el SII. Su sección es el rubro de la empresa.';
COMMENT ON COLUMN empresa.organismo_id IS 'Organismo que la entrega en marca blanca; nulo si es cliente directo.';
COMMENT ON COLUMN empresa.organismo_administrador_id IS 'Organismo administrador al que está adherida la empresa.';
COMMENT ON COLUMN empresa.codigo_contrato IS 'Número de adherente o de contrato con que el organismo (o Paritario, si es cliente directo) identifica a la empresa. Une el SSO y las sincronizaciones.';
CREATE INDEX empresa_organismo_idx ON empresa (organismo_id);
CREATE UNIQUE INDEX empresa_contrato_uq ON empresa (coalesce(organismo_id, 0), codigo_contrato) WHERE codigo_contrato IS NOT NULL;

CREATE TABLE sucursal (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    empresa_id         bigint NOT NULL REFERENCES empresa(id),
    alias              varchar(120),
    nombre             varchar(160) NOT NULL,
    direccion_calle    varchar(160),
    direccion_numero   varchar(20),
    comuna_id          int REFERENCES comuna(id),
    masa_trabajadores  int CHECK (masa_trabajadores >= 0),
    estado             sucursal_estado NOT NULL DEFAULT 'vigente',
    codigo_externo     varchar(40)
);
COMMENT ON TABLE sucursal IS 'Centro de trabajo donde se constituye un comité.';
COMMENT ON COLUMN sucursal.codigo_externo IS 'Código del centro en el sistema del cliente u organismo; une la sincronización de centros.';
CREATE INDEX sucursal_empresa_idx ON sucursal (empresa_id);
CREATE UNIQUE INDEX sucursal_codigo_externo_uq ON sucursal (empresa_id, codigo_externo) WHERE codigo_externo IS NOT NULL;

-- Integraciones con sistemas del cliente: un organismo (marca blanca) o una
-- empresa cliente directa. Una empresa solo integra su inicio de sesión y sus
-- centros; el listado de empresas es propio de un organismo.
CREATE TABLE integracion (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organismo_id           bigint REFERENCES organismo(id),
    empresa_id             bigint REFERENCES empresa(id),
    tipo                   integracion_tipo NOT NULL,
    protocolo              varchar(30) NOT NULL,
    configuracion          jsonb NOT NULL DEFAULT '{}'::jsonb,
    secreto_ref            varchar(200),
    estado                 integracion_estado NOT NULL DEFAULT 'en_prueba',
    ultima_sincronizacion  timestamptz,
    CHECK (num_nonnulls(organismo_id, empresa_id) = 1),
    CHECK (empresa_id IS NULL OR tipo IN ('sso', 'centros')),
    UNIQUE NULLS NOT DISTINCT (organismo_id, empresa_id, tipo)
);
COMMENT ON TABLE  integracion IS 'Conexión con sistemas del organismo o de la empresa cliente: inicio de sesión (SSO), empresas o contratos, centros de trabajo, certificación y reportes.';
COMMENT ON COLUMN integracion.configuracion IS 'Parámetros sin secretos (URL del servicio, atributos del SSO).';
COMMENT ON COLUMN integracion.secreto_ref IS 'Nombre del secreto en Secrets Manager con las credenciales del servicio. Nunca el secreto mismo.';

-- Bitácora de cada sincronización de empresas o centros.
CREATE TABLE sincronizacion (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    integracion_id  bigint NOT NULL REFERENCES integracion(id),
    inicio          timestamptz NOT NULL DEFAULT now(),
    fin             timestamptz,
    estado          sincronizacion_estado NOT NULL,
    nuevos          int NOT NULL DEFAULT 0 CHECK (nuevos >= 0),
    actualizados    int NOT NULL DEFAULT 0 CHECK (actualizados >= 0),
    bajas           int NOT NULL DEFAULT 0 CHECK (bajas >= 0),
    errores         int NOT NULL DEFAULT 0 CHECK (errores >= 0),
    detalle         jsonb NOT NULL DEFAULT '[]'::jsonb,
    archivo_key     varchar(300)
);
COMMENT ON TABLE  sincronizacion IS 'Resultado de cada carga desde un servicio del cliente u organismo.';
COMMENT ON COLUMN sincronizacion.detalle IS 'Errores por registro: código externo y motivo, sin datos personales.';
CREATE INDEX sincronizacion_integracion_idx ON sincronizacion (integracion_id, inicio DESC);

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
    cognito_sub     uuid UNIQUE,
    estado          usuario_estado NOT NULL DEFAULT 'invitado',
    mfa_habilitado  boolean NOT NULL DEFAULT false,
    ultimo_acceso   timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (estado <> 'activo' OR cognito_sub IS NOT NULL)
);
COMMENT ON TABLE  usuario IS 'Cuenta de acceso. Las contraseñas y el MFA los gestiona Cognito: aquí no se guarda ninguna clave. persona_id es nulo en cuentas de servicio.';
COMMENT ON COLUMN usuario.rut IS 'Nombre de usuario en Cognito.';
COMMENT ON COLUMN usuario.cognito_sub IS 'Identificador (sub) de la cuenta en Cognito; se completa en el primer ingreso. Une el token con el usuario.';
COMMENT ON COLUMN usuario.estado IS 'invitado: alta pedida, sin primer ingreso · activo: ya ingresó · bloqueado: acceso suspendido (nunca se borra).';
COMMENT ON COLUMN usuario.mfa_habilitado IS 'Copia informativa del estado de MFA en Cognito.';

CREATE TABLE rol (
    id           smallint PRIMARY KEY,
    codigo       varchar(20) NOT NULL UNIQUE,
    nombre       varchar(80) NOT NULL,
    descripcion  varchar(200),
    es_de_organismo boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE  rol IS 'Rol funcional del sistema.';
COMMENT ON COLUMN rol.es_de_organismo IS 'true para roles con ámbito de organismo (marca blanca).';

-- Equivalencia entre el rol que envía el SSO del cliente y el rol de Paritario.
CREATE TABLE rol_externo (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    integracion_id  bigint NOT NULL REFERENCES integracion(id),
    valor           varchar(100) NOT NULL,
    rol_id          smallint NOT NULL REFERENCES rol(id),
    UNIQUE (integracion_id, valor)
);
COMMENT ON TABLE rol_externo IS 'Rol del sistema del cliente (valor que llega en el SSO) → rol de empresa de Paritario: administrador, coordinador o auditor.';


CREATE TABLE usuario_rol (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id    bigint   NOT NULL REFERENCES usuario(id),
    rol_id        smallint NOT NULL REFERENCES rol(id),
    organismo_id  bigint REFERENCES organismo(id),
    empresa_id    bigint REFERENCES empresa(id),
    comite_id     bigint REFERENCES comite(id),
    vigente       boolean NOT NULL DEFAULT true,
    origen        acceso_origen NOT NULL DEFAULT 'manual',
    integracion_id bigint REFERENCES integracion(id),
    created_at    timestamptz NOT NULL DEFAULT now(),
    -- Un acceso que viene del SSO de un cliente recuerda de qué integración.
    CHECK ((origen = 'sso') = (integracion_id IS NOT NULL)),
    -- Exactamente un ámbito principal: organismo o empresa.
    CHECK (num_nonnulls(organismo_id, empresa_id) = 1),
    -- Un ámbito de comité siempre va dentro de una empresa.
    CHECK (comite_id IS NULL OR empresa_id IS NOT NULL)
);
COMMENT ON TABLE usuario_rol IS 'Asignación de rol CON ámbito: base del control de acceso y de la seguridad por fila.';
COMMENT ON COLUMN usuario_rol.origen IS 'manual: asignado en Paritario · solicitud: autoservicio aprobado · sso: lo entrega el SSO del cliente en cada ingreso (la sincronización solo toca estos).';
CREATE INDEX usuario_rol_sso_idx ON usuario_rol (usuario_id, integracion_id) WHERE origen = 'sso';

-- Un rol externo solo puede equivaler a un rol de empresa.
CREATE FUNCTION validar_rol_externo() RETURNS trigger
LANGUAGE plpgsql SET search_path = paritario, pg_temp AS $$
BEGIN
    IF (SELECT es_de_organismo FROM rol WHERE id = NEW.rol_id) THEN
        RAISE EXCEPTION 'El rol externo "%" solo puede equivaler a un rol de empresa (administrador, coordinador o auditor)', NEW.valor;
    END IF;
    IF (SELECT tipo FROM integracion WHERE id = NEW.integracion_id) <> 'sso' THEN
        RAISE EXCEPTION 'Los roles externos pertenecen a una integración de tipo sso';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER rol_externo_valida BEFORE INSERT OR UPDATE ON rol_externo
    FOR EACH ROW EXECUTE FUNCTION validar_rol_externo();
CREATE INDEX usuario_rol_usuario_idx ON usuario_rol (usuario_id) WHERE vigente;

-- Coherencia entre el rol y su ámbito, y entre el comité y la empresa.
CREATE FUNCTION validar_usuario_rol() RETURNS trigger
LANGUAGE plpgsql SET search_path = paritario, pg_temp AS $$
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
    seccion        char(1) NOT NULL REFERENCES actividad_seccion(codigo),
    nombre         varchar(160) NOT NULL,
    ds_referencia  varchar(20) DEFAULT 'DS 44',
    descripcion    text,
    vigente        boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE  programa_plantilla IS 'Programa de trabajo propuesto según rubro.';
COMMENT ON COLUMN programa_plantilla.organismo_id IS 'Nulo = plantilla general de la plataforma.';
COMMENT ON COLUMN programa_plantilla.seccion IS 'Rubro (sección CIIU) al que aplica la plantilla.';

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
    seccion       char(1) REFERENCES actividad_seccion(codigo),
    descripcion   text,
    CHECK (num_nonnulls(archivo_key, url) >= 1)
);
COMMENT ON TABLE  material_apoyo IS 'Biblioteca de material (videos, guías, formatos).';
COMMENT ON COLUMN material_apoyo.organismo_id IS 'Nulo = material general de la plataforma.';
COMMENT ON COLUMN material_apoyo.seccion IS 'Rubro (sección CIIU) al que aplica; nulo = todos los rubros.';

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
    archivo_version           varchar(200),
    estado                    documento_estado NOT NULL DEFAULT 'pendiente',
    sha256                    char(64) CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    mime                      varchar(80),
    tamano_bytes              bigint CHECK (tamano_bytes >= 0),
    fecha_documento           date,
    fecha_carga               timestamptz NOT NULL DEFAULT now(),
    contiene_datos_sensibles  boolean NOT NULL DEFAULT false,
    vigente                   boolean NOT NULL DEFAULT true,
    cargado_por               bigint REFERENCES usuario(id),
    CHECK (estado = 'pendiente' OR (sha256 IS NOT NULL AND tamano_bytes IS NOT NULL))
);
COMMENT ON TABLE  documento IS 'Acta, certificado u otro archivo del comité. El binario vive en S3; aquí solo su ruta.';
COMMENT ON COLUMN documento.estado IS 'El navegador sube el archivo directo a S3 con una URL firmada: el registro nace pendiente y pasa a disponible cuando la API confirma el objeto.';
COMMENT ON COLUMN documento.archivo_version IS 'Versión del objeto en el bucket versionado: fija qué archivo corresponde a este registro.';
COMMENT ON COLUMN documento.sha256 IS 'Huella del archivo, para verificar su integridad.';
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

-- -----------------------------------------------------------------------------
-- Investigación de accidentes y enfermedades profesionales (comisión del comité)
-- -----------------------------------------------------------------------------

-- Códigos del Manual Técnico de Codificación SISESAT (SUSESO), Esquema N°2.
-- Cada clasificación se carga desde su anexo oficial:
--   forma_accidente      Forma del accidente, OIT ................ Anexo II
--   agente_material      Agente material del accidente y de la
--                        lesión, OIT ............................. Anexo III
--   ubicacion_lesion     Ubicación anatómica de la lesión, OIT,
--                        con lateralidad en el tercer carácter ..... Anexo VI
--   causa_externa_cie10  CIE-10 cap. XX: causa externa e
--                        intencionalidad ......................... Anexo I
--   lesion_cie10         CIE-10 cap. XIX: naturaleza de la lesión .. Anexo V
--   agente_enfermedad    Lista europea de agentes causantes de
--                        enfermedades profesionales .............. Anexo IX
--   enfermedad_cie10     CIE-10 cap. I a XVIII: diagnóstico de la
--                        enfermedad profesional
-- El esquema no trae datos.
CREATE TABLE codigo_sisesat (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    clasificacion  sisesat_clasificacion NOT NULL,
    codigo         varchar(12)  NOT NULL,
    descripcion    varchar(300) NOT NULL,
    codigo_padre   varchar(12),
    codigo_alterno varchar(12),
    grupo          varchar(300),
    terminos       text[] NOT NULL DEFAULT '{}',
    seleccionable  boolean NOT NULL DEFAULT true,
    observacion    text,
    vigente        boolean NOT NULL DEFAULT true,
    UNIQUE (clasificacion, codigo)
);
COMMENT ON TABLE  codigo_sisesat IS 'Códigos de codificación SISESAT (SUSESO) para accidentes y enfermedades profesionales.';
COMMENT ON COLUMN codigo_sisesat.codigo_padre IS 'Código del nivel superior: forma OIT de 2 dígitos (11 para 11.1), agente OIT (234 para 234.1) o categoría CIE-10 (W01 para W010).';
COMMENT ON COLUMN codigo_sisesat.grupo IS 'Agrupación con que el anexo presenta el código.';
COMMENT ON COLUMN codigo_sisesat.codigo_alterno IS 'Otra grafía oficial del código (Anexo VI: 121 para 1.2.1).';
COMMENT ON COLUMN codigo_sisesat.terminos IS 'Otras glosas del anexo para el mismo código (Anexo V); sirven para buscar.';
COMMENT ON COLUMN codigo_sisesat.seleccionable IS 'false = agrupación que el anexo indica no ingresar (Anexo IX).';
COMMENT ON COLUMN codigo_sisesat.observacion IS 'Anomalías del anexo para este código.';

-- Anexo IV: equivalencias entre la causa externa (CIE-10 cap. XX) y la forma
-- y el agente material OIT. Permiten sugerir forma y agente al codificar.
-- Solo se guardan opciones que existen en los Anexos II y III (2018); lo que
-- el anexo trae y no calza queda anotado en observacion.
CREATE TABLE equivalencia_cie10_oit (
    cie10_codigo  varchar(10) PRIMARY KEY,
    formas_oit    varchar(10)[] NOT NULL DEFAULT '{}',
    agentes_oit   varchar(10)[] NOT NULL DEFAULT '{}',
    texto_forma   varchar(60),
    texto_agente  varchar(60),
    observacion   text
);
COMMENT ON TABLE  equivalencia_cie10_oit IS 'Anexo IV SISESAT: forma y agente OIT aceptables para cada causa externa CIE-10.';
COMMENT ON COLUMN equivalencia_cie10_oit.formas_oit IS 'Códigos OIT de forma (2 dígitos) válidos en el Anexo II; vacío = sin equivalencia, se codifica directo.';
COMMENT ON COLUMN equivalencia_cie10_oit.agentes_oit IS 'Códigos de agente válidos en el Anexo III (rangos ya expandidos); vacío = sin equivalencia.';
COMMENT ON COLUMN equivalencia_cie10_oit.texto_forma IS 'Valor tal como aparece en el Anexo IV.';
COMMENT ON COLUMN equivalencia_cie10_oit.observacion IS 'Anomalías del Anexo IV para esta fila.';

-- Sugerencias de forma y agente para una causa externa, según el Anexo IV.
-- Devuelve los códigos de detalle cuyo código OIT figura en la equivalencia.
CREATE FUNCTION sugerencias_sisesat(p_cie10 varchar) RETURNS TABLE (
    clasificacion sisesat_clasificacion, codigo varchar, descripcion varchar)
LANGUAGE sql STABLE SET search_path = paritario, pg_temp AS $$
    SELECT cs.clasificacion, cs.codigo, cs.descripcion
    FROM equivalencia_cie10_oit e
    JOIN codigo_sisesat cs
      ON (cs.clasificacion = 'forma_accidente'
          AND coalesce(cs.codigo_padre, cs.codigo) = ANY (e.formas_oit))
      OR (cs.clasificacion = 'agente_material'
          AND (cs.codigo = ANY (e.agentes_oit) OR cs.codigo_padre = ANY (e.agentes_oit)))
    WHERE e.cie10_codigo = p_cie10 AND cs.vigente AND cs.seleccionable
    ORDER BY cs.clasificacion, cs.codigo
$$;

CREATE TABLE investigacion_accidente (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    comite_id              bigint NOT NULL REFERENCES comite(id),
    comision_id            bigint REFERENCES comision(id),
    sucursal_id            bigint REFERENCES sucursal(id),
    persona_id             bigint REFERENCES persona(id),
    tipo                   siniestro_tipo NOT NULL,
    gravedad               siniestro_gravedad NOT NULL DEFAULT 'leve',
    fecha_evento           timestamptz NOT NULL,
    folio_denuncia         varchar(40),
    descripcion            text NOT NULL,
    dias_perdidos          int CHECK (dias_perdidos >= 0),
    forma_id               bigint REFERENCES codigo_sisesat(id),
    agente_accidente_id    bigint REFERENCES codigo_sisesat(id),
    agente_lesion_id       bigint REFERENCES codigo_sisesat(id),
    naturaleza_lesion_id   bigint REFERENCES codigo_sisesat(id),
    ubicacion_lesion_id    bigint REFERENCES codigo_sisesat(id),
    causa_externa_id       bigint REFERENCES codigo_sisesat(id),
    agente_enfermedad_id   bigint REFERENCES codigo_sisesat(id),
    diagnostico_enfermedad_id bigint REFERENCES codigo_sisesat(id),
    estado                 investigacion_estado NOT NULL DEFAULT 'abierta',
    fecha_cierre           date,
    informe_documento_id   bigint REFERENCES documento(id),
    created_at             timestamptz NOT NULL DEFAULT now(),
    CHECK ((estado = 'cerrada') = (fecha_cierre IS NOT NULL)),
    -- Manual SISESAT: el accidente se codifica por lesión y causa externa;
    -- la enfermedad profesional, por diagnóstico y agente causal.
    CHECK (tipo = 'enfermedad_profesional'
           OR (agente_enfermedad_id IS NULL AND diagnostico_enfermedad_id IS NULL)),
    CHECK (tipo <> 'enfermedad_profesional'
           OR num_nonnulls(forma_id, agente_accidente_id, agente_lesion_id,
                           naturaleza_lesion_id, causa_externa_id) = 0)
);
COMMENT ON TABLE  investigacion_accidente IS 'Investigación de un accidente o enfermedad profesional por la comisión del comité. Contiene datos de salud: acceso reforzado.';
COMMENT ON COLUMN investigacion_accidente.persona_id IS 'Persona afectada. Dato sensible: solo visible con ámbito de empresa o comité.';
COMMENT ON COLUMN investigacion_accidente.folio_denuncia IS 'Folio de la DIAT o DIEP ante el organismo administrador.';
CREATE INDEX investigacion_comite_idx ON investigacion_accidente (comite_id, fecha_evento);

-- Cada código SISESAT debe venir de la clasificación que corresponde a su columna.
CREATE FUNCTION validar_codigos_investigacion() RETURNS trigger
LANGUAGE plpgsql SET search_path = paritario, pg_temp AS $$
DECLARE
    par record;
BEGIN
    FOR par IN SELECT * FROM (VALUES
        (NEW.forma_id,                  'forma_accidente'::sisesat_clasificacion),
        (NEW.agente_accidente_id,       'agente_material'),
        (NEW.agente_lesion_id,          'agente_material'),
        (NEW.naturaleza_lesion_id,      'lesion_cie10'),
        (NEW.ubicacion_lesion_id,       'ubicacion_lesion'),
        (NEW.causa_externa_id,          'causa_externa_cie10'),
        (NEW.agente_enfermedad_id,      'agente_enfermedad'),
        (NEW.diagnostico_enfermedad_id, 'enfermedad_cie10')) v(id, clas)
    LOOP
        IF par.id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM codigo_sisesat WHERE id = par.id AND clasificacion = par.clas
        ) THEN
            RAISE EXCEPTION 'El código % no pertenece a la clasificación %', par.id, par.clas;
        END IF;
        IF par.id IS NOT NULL AND NOT (SELECT seleccionable FROM codigo_sisesat WHERE id = par.id) THEN
            RAISE EXCEPTION 'El código % es una agrupación: elija un ítem individual', par.id;
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;
CREATE TRIGGER investigacion_codigos_valida BEFORE INSERT OR UPDATE ON investigacion_accidente
    FOR EACH ROW EXECUTE FUNCTION validar_codigos_investigacion();

CREATE TABLE investigacion_causa (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    investigacion_id  bigint NOT NULL REFERENCES investigacion_accidente(id),
    tipo              causa_tipo NOT NULL,
    descripcion       text NOT NULL
);
COMMENT ON TABLE investigacion_causa IS 'Causas inmediatas y básicas identificadas en la investigación.';
CREATE INDEX investigacion_causa_idx ON investigacion_causa (investigacion_id);

CREATE TABLE investigacion_medida (
    id                         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    investigacion_id           bigint NOT NULL REFERENCES investigacion_accidente(id),
    jerarquia                  jerarquia_control NOT NULL,
    descripcion                text NOT NULL,
    actividad_id               bigint REFERENCES actividad(id),
    responsable_integrante_id  bigint REFERENCES comite_integrante(id),
    fecha_compromiso           date,
    estado                     medida_estado NOT NULL DEFAULT 'pendiente'
);
COMMENT ON TABLE  investigacion_medida IS 'Medidas correctivas, clasificadas según la prelación del DS 44.';
COMMENT ON COLUMN investigacion_medida.jerarquia IS 'Prelación DS 44: eliminación, sustitución, control de ingeniería, control administrativo, protección personal.';
COMMENT ON COLUMN investigacion_medida.actividad_id IS 'Actividad del programa de trabajo con que se ejecuta la medida.';
CREATE INDEX investigacion_medida_idx ON investigacion_medida (investigacion_id);

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
    SELECT coalesce(array_agg(DISTINCT p), '{}')
    FROM (
        SELECT ci.persona_id FROM comite_integrante ci
        WHERE ci.comite_id = ANY (comites_con_detalle())
        UNION
        SELECT ia.persona_id FROM investigacion_accidente ia
        WHERE ia.comite_id = ANY (comites_con_detalle()) AND ia.persona_id IS NOT NULL
    ) x(p)
$$;

-- Organismo: lo ven sus administradores y las empresas que lo usan (para la marca).
ALTER TABLE organismo ENABLE ROW LEVEL SECURITY;
CREATE POLICY organismo_ambito ON organismo
    USING (id = ANY (organismos_visibles())
           OR id IN (SELECT organismo_id FROM empresa));

ALTER TABLE integracion ENABLE ROW LEVEL SECURITY;
CREATE POLICY integracion_ambito ON integracion
    USING (organismo_id = ANY (organismos_visibles())
           OR empresa_id = ANY (empresas_visibles()));

ALTER TABLE rol_externo ENABLE ROW LEVEL SECURITY;
CREATE POLICY rol_externo_ambito ON rol_externo
    USING (integracion_id IN (SELECT id FROM integracion));

ALTER TABLE sincronizacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY sincronizacion_ambito ON sincronizacion
    USING (integracion_id IN (SELECT id FROM integracion));

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
ALTER TABLE investigacion_accidente ENABLE ROW LEVEL SECURITY;
CREATE POLICY investigacion_ambito ON investigacion_accidente
    USING (comite_id = ANY (comites_con_detalle()));

ALTER TABLE investigacion_causa ENABLE ROW LEVEL SECURITY;
CREATE POLICY investigacion_causa_ambito ON investigacion_causa
    USING (investigacion_id IN (SELECT id FROM investigacion_accidente));

ALTER TABLE investigacion_medida ENABLE ROW LEVEL SECURITY;
CREATE POLICY investigacion_medida_ambito ON investigacion_medida
    USING (investigacion_id IN (SELECT id FROM investigacion_accidente));

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

-- Indicadores de siniestralidad por comité y año, sin datos de personas.
-- No usa security_invoker: el organismo no ve los casos (seguridad por fila
-- de investigacion_accidente), pero sí estos totales de sus empresas. El
-- filtro por ámbito se aplica explícitamente con comites_visibles().
CREATE VIEW v_indicadores_siniestralidad AS
SELECT
    ia.comite_id,
    extract(year FROM ia.fecha_evento)::int                         AS anio,
    count(*) FILTER (WHERE ia.tipo = 'accidente_trabajo')           AS accidentes_trabajo,
    count(*) FILTER (WHERE ia.tipo = 'accidente_trayecto')          AS accidentes_trayecto,
    count(*) FILTER (WHERE ia.tipo = 'enfermedad_profesional')      AS enfermedades_profesionales,
    count(*) FILTER (WHERE ia.gravedad = 'grave')                   AS graves,
    count(*) FILTER (WHERE ia.gravedad = 'fatal')                   AS fatales,
    coalesce(sum(ia.dias_perdidos), 0)                              AS dias_perdidos,
    count(*) FILTER (WHERE ia.estado <> 'cerrada')                  AS investigaciones_abiertas
FROM investigacion_accidente ia
WHERE ia.comite_id = ANY (comites_visibles())
GROUP BY ia.comite_id, extract(year FROM ia.fecha_evento);
COMMENT ON VIEW v_indicadores_siniestralidad IS 'Totales de siniestralidad por comité y año, sin personas. Visible también para el organismo.';

-- =============================================================================
-- Integraciones: sincronización de empresas y centros, y accesos desde el SSO
-- =============================================================================
-- La aplicación no puede crear empresas ni ver las de otros clientes (seguridad
-- por fila). Estas funciones hacen esas operaciones acotadas a la integración
-- que se indica: solo tocan las empresas y centros de su dueño (organismo o
-- empresa), nunca borran (marcan bajas) y dejan bitácora en sincronizacion.

CREATE FUNCTION normalizar_rut(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT upper(regexp_replace(coalesce(p, ''), '[.\s]', '', 'g'))
$$;

-- Listado completo de empresas (o contratos) de un organismo. Formato:
--   [{"contrato": "A-001", "rut": "76123456-7", "razon_social": "…",
--     "nombre_fantasia": "…", "actividad": "421000", "vigente": true}, …]
-- Los contratos del organismo que no vienen en el listado quedan de baja,
-- salvo que más del 10 % de las filas tenga errores (listado sospechoso).
CREATE FUNCTION importar_empresas(p_integracion bigint, p_datos jsonb, p_archivo text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = paritario, pg_temp AS $$
DECLARE
    v_int     integracion%ROWTYPE;
    v_org     bigint;
    v_oa      smallint;
    r         jsonb;
    v_cod     text;
    v_rut     text;
    v_id      bigint;
    v_otro    bigint;
    v_estado  empresa_estado;
    v_codigos text[] := '{}';
    v_total   int;
    n_nuevos  int := 0;
    n_act     int := 0;
    n_bajas   int := 0;
    n         int;
    n_err     int;
    v_errores jsonb := '[]';
    v_sinc    bigint;
BEGIN
    SELECT * INTO v_int FROM integracion WHERE id = p_integracion;
    IF NOT FOUND OR v_int.tipo <> 'empresas' OR v_int.estado = 'inactiva' THEN
        RAISE EXCEPTION 'La integración % no es un listado de empresas activo', p_integracion;
    END IF;
    IF jsonb_typeof(p_datos) IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos) = 0 THEN
        INSERT INTO sincronizacion (integracion_id, fin, estado, detalle, archivo_key)
        VALUES (p_integracion, now(), 'fallida', '[{"motivo": "listado vacío o con formato inválido"}]', p_archivo)
        RETURNING id INTO v_sinc;
        RETURN v_sinc;
    END IF;
    v_org := v_int.organismo_id;
    SELECT organismo_administrador_id INTO v_oa FROM organismo WHERE id = v_org;
    v_total := jsonb_array_length(p_datos);

    FOR r IN SELECT value FROM jsonb_array_elements(p_datos) LOOP
        v_cod := nullif(trim(r->>'contrato'), '');
        v_id := NULL;
        BEGIN
            IF v_cod IS NULL THEN
                RAISE EXCEPTION 'sin código de contrato';
            END IF;
            IF v_cod = ANY (v_codigos) THEN
                RAISE EXCEPTION 'contrato repetido en el listado';
            END IF;
            v_codigos := v_codigos || v_cod;
            v_rut := normalizar_rut(r->>'rut');
            IF NOT rut_valido(v_rut) THEN
                RAISE EXCEPTION 'RUT de empresa inválido';
            END IF;
            v_estado := CASE WHEN coalesce((r->>'vigente')::boolean, true) THEN 'activo' ELSE 'baja' END;

            SELECT id INTO v_id FROM empresa WHERE organismo_id = v_org AND codigo_contrato = v_cod;
            IF v_id IS NULL THEN
                SELECT id INTO v_otro FROM empresa WHERE rut = v_rut;
                IF v_otro IS NOT NULL THEN
                    IF (SELECT organismo_id FROM empresa WHERE id = v_otro) IS DISTINCT FROM v_org THEN
                        RAISE EXCEPTION 'la empresa ya es cliente de Paritario por otra vía';
                    END IF;
                    v_id := v_otro;  -- empresa del organismo que aún no tenía contrato
                ELSE
                    INSERT INTO empresa (rut, razon_social, nombre_fantasia, actividad_economica_codigo,
                                         organismo_id, organismo_administrador_id, codigo_contrato, estado)
                    VALUES (v_rut, r->>'razon_social', r->>'nombre_fantasia', nullif(r->>'actividad', ''),
                            v_org, v_oa, v_cod, v_estado);
                    n_nuevos := n_nuevos + 1;
                    CONTINUE;
                END IF;
            ELSIF (SELECT rut FROM empresa WHERE id = v_id) <> v_rut THEN
                RAISE EXCEPTION 'el contrato ya corresponde a otro RUT';
            END IF;

            UPDATE empresa SET
                codigo_contrato            = v_cod,
                razon_social               = coalesce(r->>'razon_social', razon_social),
                nombre_fantasia            = coalesce(r->>'nombre_fantasia', nombre_fantasia),
                actividad_economica_codigo = coalesce(nullif(r->>'actividad', ''), actividad_economica_codigo),
                estado                     = v_estado
            WHERE id = v_id
              AND (codigo_contrato, razon_social, nombre_fantasia, actividad_economica_codigo, estado)
                  IS DISTINCT FROM
                  (v_cod, coalesce(r->>'razon_social', razon_social), coalesce(r->>'nombre_fantasia', nombre_fantasia),
                   coalesce(nullif(r->>'actividad', ''), actividad_economica_codigo), v_estado);
            GET DIAGNOSTICS n = ROW_COUNT;
            n_act := n_act + n;
        EXCEPTION WHEN others THEN
            v_errores := v_errores || jsonb_build_object('contrato', v_cod, 'motivo', SQLERRM);
        END;
    END LOOP;

    n_err := jsonb_array_length(v_errores);
    IF n_err * 10 <= v_total THEN
        UPDATE empresa SET estado = 'baja'
        WHERE organismo_id = v_org AND codigo_contrato IS NOT NULL
          AND NOT (codigo_contrato = ANY (v_codigos)) AND estado <> 'baja';
        GET DIAGNOSTICS n_bajas = ROW_COUNT;
    ELSE
        v_errores := v_errores || '{"motivo": "más del 10 % de filas con error: no se aplicaron bajas"}'::jsonb;
    END IF;

    INSERT INTO sincronizacion (integracion_id, fin, estado, nuevos, actualizados, bajas, errores, detalle, archivo_key)
    VALUES (p_integracion, now(),
            CASE WHEN jsonb_array_length(v_errores) = 0 THEN 'correcta' ELSE 'con_errores' END::sincronizacion_estado,
            n_nuevos, n_act, n_bajas, n_err, v_errores, p_archivo)
    RETURNING id INTO v_sinc;
    UPDATE integracion SET ultima_sincronizacion = now() WHERE id = p_integracion;
    RETURN v_sinc;
END;
$$;
COMMENT ON FUNCTION importar_empresas IS 'Sincroniza el listado de empresas o contratos de un organismo. Devuelve el id de sincronizacion.';

-- Listado completo de centros de trabajo. Formato:
--   [{"contrato": "A-001", "codigo": "CT-12", "nombre": "…", "alias": "…",
--     "calle": "…", "numero": "…", "comuna": "13101", "trabajadores": 120,
--     "vigente": true}, …]
-- Si la integración es de una empresa, "contrato" se ignora.
CREATE FUNCTION importar_centros(p_integracion bigint, p_datos jsonb, p_archivo text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = paritario, pg_temp AS $$
DECLARE
    v_int      integracion%ROWTYPE;
    r          jsonb;
    v_emp      bigint;
    v_cod      text;
    v_ref      text;
    v_id       bigint;
    v_comuna   int;
    v_estado   sucursal_estado;
    v_vistos   text[] := '{}';
    v_empresas bigint[];
    v_total    int;
    n_nuevos   int := 0;
    n_act      int := 0;
    n_bajas    int := 0;
    n          int;
    n_err      int;
    v_errores  jsonb := '[]';
    v_sinc     bigint;
BEGIN
    SELECT * INTO v_int FROM integracion WHERE id = p_integracion;
    IF NOT FOUND OR v_int.tipo <> 'centros' OR v_int.estado = 'inactiva' THEN
        RAISE EXCEPTION 'La integración % no es un listado de centros activo', p_integracion;
    END IF;
    IF jsonb_typeof(p_datos) IS DISTINCT FROM 'array' OR jsonb_array_length(p_datos) = 0 THEN
        INSERT INTO sincronizacion (integracion_id, fin, estado, detalle, archivo_key)
        VALUES (p_integracion, now(), 'fallida', '[{"motivo": "listado vacío o con formato inválido"}]', p_archivo)
        RETURNING id INTO v_sinc;
        RETURN v_sinc;
    END IF;
    v_empresas := CASE WHEN v_int.empresa_id IS NOT NULL THEN ARRAY[v_int.empresa_id]
                       ELSE ARRAY(SELECT id FROM empresa WHERE organismo_id = v_int.organismo_id) END;
    v_total := jsonb_array_length(p_datos);

    FOR r IN SELECT value FROM jsonb_array_elements(p_datos) LOOP
        v_cod := nullif(trim(r->>'codigo'), '');
        v_ref := coalesce(r->>'contrato', '') || '/' || coalesce(v_cod, '');
        BEGIN
            IF v_cod IS NULL THEN
                RAISE EXCEPTION 'sin código de centro';
            END IF;
            IF v_int.empresa_id IS NOT NULL THEN
                v_emp := v_int.empresa_id;
            ELSE
                SELECT id INTO v_emp FROM empresa
                WHERE organismo_id = v_int.organismo_id AND codigo_contrato = r->>'contrato';
                IF v_emp IS NULL THEN
                    RAISE EXCEPTION 'contrato desconocido';
                END IF;
            END IF;
            IF (v_emp || ':' || v_cod) = ANY (v_vistos) THEN
                RAISE EXCEPTION 'centro repetido en el listado';
            END IF;
            v_vistos := v_vistos || (v_emp || ':' || v_cod);
            v_comuna := NULL;
            IF nullif(r->>'comuna', '') IS NOT NULL THEN
                SELECT id INTO v_comuna FROM comuna WHERE codigo = lpad(r->>'comuna', 5, '0');
                IF v_comuna IS NULL THEN
                    RAISE EXCEPTION 'comuna desconocida';
                END IF;
            END IF;
            v_estado := CASE WHEN coalesce((r->>'vigente')::boolean, true) THEN 'vigente' ELSE 'no_vigente' END;

            SELECT id INTO v_id FROM sucursal WHERE empresa_id = v_emp AND codigo_externo = v_cod;
            IF v_id IS NULL THEN
                INSERT INTO sucursal (empresa_id, codigo_externo, nombre, alias, direccion_calle,
                                      direccion_numero, comuna_id, masa_trabajadores, estado)
                VALUES (v_emp, v_cod, r->>'nombre', r->>'alias', r->>'calle', r->>'numero', v_comuna,
                        (r->>'trabajadores')::int, v_estado);
                n_nuevos := n_nuevos + 1;
            ELSE
                UPDATE sucursal SET
                    nombre            = coalesce(r->>'nombre', nombre),
                    alias             = coalesce(r->>'alias', alias),
                    direccion_calle   = coalesce(r->>'calle', direccion_calle),
                    direccion_numero  = coalesce(r->>'numero', direccion_numero),
                    comuna_id         = coalesce(v_comuna, comuna_id),
                    masa_trabajadores = coalesce((r->>'trabajadores')::int, masa_trabajadores),
                    estado            = v_estado
                WHERE id = v_id
                  AND (nombre, alias, direccion_calle, direccion_numero, comuna_id, masa_trabajadores, estado)
                      IS DISTINCT FROM
                      (coalesce(r->>'nombre', nombre), coalesce(r->>'alias', alias),
                       coalesce(r->>'calle', direccion_calle), coalesce(r->>'numero', direccion_numero),
                       coalesce(v_comuna, comuna_id), coalesce((r->>'trabajadores')::int, masa_trabajadores), v_estado);
                GET DIAGNOSTICS n = ROW_COUNT;
                n_act := n_act + n;
            END IF;
        EXCEPTION WHEN others THEN
            v_errores := v_errores || jsonb_build_object('centro', v_ref, 'motivo', SQLERRM);
        END;
    END LOOP;

    n_err := jsonb_array_length(v_errores);
    IF n_err * 10 <= v_total THEN
        UPDATE sucursal SET estado = 'no_vigente'
        WHERE empresa_id = ANY (v_empresas) AND codigo_externo IS NOT NULL
          AND NOT ((empresa_id || ':' || codigo_externo) = ANY (v_vistos)) AND estado <> 'no_vigente';
        GET DIAGNOSTICS n_bajas = ROW_COUNT;
    ELSE
        v_errores := v_errores || '{"motivo": "más del 10 % de filas con error: no se aplicaron bajas"}'::jsonb;
    END IF;

    INSERT INTO sincronizacion (integracion_id, fin, estado, nuevos, actualizados, bajas, errores, detalle, archivo_key)
    VALUES (p_integracion, now(),
            CASE WHEN jsonb_array_length(v_errores) = 0 THEN 'correcta' ELSE 'con_errores' END::sincronizacion_estado,
            n_nuevos, n_act, n_bajas, n_err, v_errores, p_archivo)
    RETURNING id INTO v_sinc;
    UPDATE integracion SET ultima_sincronizacion = now() WHERE id = p_integracion;
    RETURN v_sinc;
END;
$$;
COMMENT ON FUNCTION importar_centros IS 'Sincroniza los centros de trabajo de un organismo (por contrato) o de una empresa cliente. Devuelve el id de sincronizacion.';

-- Accesos desde el SSO del cliente, en cada ingreso. El SSO entrega el RUT,
-- un rol externo y los contratos del usuario. Deja vigentes solo los accesos
-- que corresponden y revoca los demás accesos de origen sso de esa
-- integración; los asignados a mano o por solicitud no se tocan.
-- Devuelve el id del usuario.
CREATE FUNCTION sincronizar_accesos_sso(p_integracion bigint, p_rut text, p_cognito_sub uuid,
                                        p_rol_externo text, p_contratos text[] DEFAULT '{}')
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = paritario, pg_temp AS $$
DECLARE
    v_int  integracion%ROWTYPE;
    v_rut  text := normalizar_rut(p_rut);
    v_usr  usuario%ROWTYPE;
    v_rol  smallint;
    v_emps bigint[];
    v_emp  bigint;
BEGIN
    SELECT * INTO v_int FROM integracion WHERE id = p_integracion;
    IF NOT FOUND OR v_int.tipo <> 'sso' OR v_int.estado = 'inactiva' THEN
        RAISE EXCEPTION 'La integración % no es un SSO activo', p_integracion;
    END IF;
    IF p_cognito_sub IS NULL THEN
        RAISE EXCEPTION 'Falta el identificador de la cuenta';
    END IF;

    SELECT * INTO v_usr FROM usuario WHERE rut = v_rut;
    IF NOT FOUND THEN
        INSERT INTO usuario (rut, persona_id, cognito_sub, estado, ultimo_acceso)
        VALUES (v_rut, (SELECT id FROM persona WHERE rut = v_rut), p_cognito_sub, 'activo', now())
        RETURNING * INTO v_usr;
    ELSE
        IF v_usr.estado = 'bloqueado' THEN
            RAISE EXCEPTION 'La cuenta está bloqueada';
        END IF;
        IF v_usr.cognito_sub IS NOT NULL AND v_usr.cognito_sub <> p_cognito_sub THEN
            RAISE EXCEPTION 'El RUT ya está asociado a otra cuenta';
        END IF;
        UPDATE usuario SET cognito_sub = p_cognito_sub, estado = 'activo', ultimo_acceso = now()
        WHERE id = v_usr.id;
    END IF;

    SELECT rol_id INTO v_rol FROM rol_externo WHERE integracion_id = p_integracion AND valor = p_rol_externo;
    IF v_rol IS NULL THEN
        v_emps := '{}';
    ELSIF v_int.empresa_id IS NOT NULL THEN
        v_emps := ARRAY[v_int.empresa_id];
    ELSE
        v_emps := ARRAY(SELECT id FROM empresa
                        WHERE organismo_id = v_int.organismo_id
                          AND codigo_contrato = ANY (coalesce(p_contratos, '{}'))
                          AND estado <> 'baja');
    END IF;

    UPDATE usuario_rol SET vigente = false
    WHERE usuario_id = v_usr.id AND origen = 'sso' AND integracion_id = p_integracion AND vigente
      AND NOT (rol_id IS NOT DISTINCT FROM v_rol AND empresa_id = ANY (v_emps));

    FOREACH v_emp IN ARRAY v_emps LOOP
        UPDATE usuario_rol SET vigente = true
        WHERE usuario_id = v_usr.id AND origen = 'sso' AND integracion_id = p_integracion
          AND rol_id = v_rol AND empresa_id = v_emp AND comite_id IS NULL;
        IF NOT FOUND THEN
            INSERT INTO usuario_rol (usuario_id, rol_id, empresa_id, origen, integracion_id)
            VALUES (v_usr.id, v_rol, v_emp, 'sso', p_integracion);
        END IF;
    END LOOP;
    RETURN v_usr.id;
END;
$$;
COMMENT ON FUNCTION sincronizar_accesos_sso IS 'Concilia los accesos que entrega el SSO de un cliente en cada ingreso. Solo toca accesos de origen sso de esa integración.';

-- Solo la aplicación ejecuta estas funciones (no el público).
REVOKE EXECUTE ON FUNCTION importar_empresas(bigint, jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION importar_centros(bigint, jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION sincronizar_accesos_sso(bigint, text, uuid, text, text[]) FROM PUBLIC;

COMMIT;
