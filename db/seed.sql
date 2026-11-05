-- =============================================================================
-- Paritario — datos base (catálogos). Ejecutar después de schema.sql.
-- =============================================================================

BEGIN;
SET search_path = paritario, public;

-- Regiones de Chile: id = número oficial; orden = de norte a sur.
INSERT INTO region (id, nombre, orden) VALUES
    (15, 'Arica y Parinacota', 1),
    (1,  'Tarapacá', 2),
    (2,  'Antofagasta', 3),
    (3,  'Atacama', 4),
    (4,  'Coquimbo', 5),
    (5,  'Valparaíso', 6),
    (13, 'Metropolitana de Santiago', 7),
    (6,  'Libertador General Bernardo O''Higgins', 8),
    (7,  'Maule', 9),
    (16, 'Ñuble', 10),
    (8,  'Biobío', 11),
    (9,  'La Araucanía', 12),
    (14, 'Los Ríos', 13),
    (10, 'Los Lagos', 14),
    (11, 'Aisén del General Carlos Ibáñez del Campo', 15),
    (12, 'Magallanes y de la Antártica Chilena', 16);

-- Comunas: en db/seed_comunas.sql (346 comunas con su código único territorial).

-- Roles del sistema.
INSERT INTO rol (id, codigo, nombre, descripcion, es_de_organismo) VALUES
    (1, 'ADMIN_ORGANISMO',  'Administrador de organismo', 'Configura marca e integraciones; ve indicadores de todas las empresas del organismo', true),
    (2, 'ASESOR_ORGANISMO', 'Asesor del organismo',       'Acompaña a las empresas asignadas; ve sus indicadores', true),
    (3, 'ADMIN_EMPRESA',    'Administrador de empresa',   'Gestiona comités, centros y accesos de su empresa', false),
    (4, 'COORDINADOR',      'Coordinador de comité',      'Gestiona integrantes, programa, reuniones y actas de su comité', false),
    (5, 'AUDITOR',          'Auditor',                    'Realiza auditorías y certificación', false);

-- Niveles de certificación generales (los organismos pueden definir los suyos).
INSERT INTO nivel_certificacion (organismo_id, codigo, nombre) VALUES
    (NULL, 'inicial',    'Inicial'),
    (NULL, 'intermedio', 'Intermedio'),
    (NULL, 'avanzado',   'Avanzado');

COMMIT;
