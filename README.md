# Paritario — Comités Paritarios de Higiene y Seguridad

Plataforma independiente para que cualquier empresa constituya y gestione sus Comités Paritarios de Higiene y Seguridad (CPHS) según el DS 44/2024: integrantes, comisiones, programa de trabajo, reuniones, actas y certificación.

Funciona en dos modos con la misma instalación:

- **Venta directa** a empresas, sin importar su mutualidad u organismo administrador.
- **Marca blanca** para organismos administradores (mutualidades o servicios públicos) que la entregan a sus empresas adherentes con su propia marca.

Este repositorio contiene, por ahora, el diseño del producto y el esquema de base de datos. Todavía no hay código de aplicación.

## Contenido

| Ruta | Qué es |
| --- | --- |
| [`docs/especificacion-funcional.md`](docs/especificacion-funcional.md) | Especificación funcional: módulos, roles, requisitos, cumplimiento, roadmap, costos, comparación de nubes y oferta para organismos |
| [`docs/prototipo.html`](docs/prototipo.html) | Prototipo navegable con datos de ejemplo (incluye el perfil de organismo en marca blanca) |
| [`docs/modelo-datos.html`](docs/modelo-datos.html) | Modelo de datos v5: diagrama entidad-relación y las 30 tablas |
| [`docs/anexo-privacidad.html`](docs/anexo-privacidad.html) | Anexo de privacidad según la Ley 21.719 |
| [`docs/arquitectura-aws.html`](docs/arquitectura-aws.html) | Arquitectura de referencia en AWS |
| [`db/schema.sql`](db/schema.sql) | Esquema PostgreSQL 16: tablas, restricciones y seguridad por fila |
| [`db/seed.sql`](db/seed.sql) | Catálogos base: regiones, roles y niveles de certificación generales |
| [`db/seed_comunas.sql`](db/seed_comunas.sql) | Las 346 comunas con su código único territorial (CUT) vigente desde 2018 |
| [`db/test_rls.sql`](db/test_rls.sql) | Prueba del aislamiento entre empresas y organismos, y de las reglas de negocio |

Los archivos HTML se abren directamente en el navegador. El diagrama entidad-relación del modelo de datos carga la librería Mermaid desde cdnjs, así que necesita conexión a internet.

## Base de datos

Requiere PostgreSQL 16 (usa `UNIQUE NULLS NOT DISTINCT`, disponible desde la versión 15).

```bash
createdb paritario
```

```bash
psql -d paritario -v ON_ERROR_STOP=1 -f db/schema.sql -f db/seed.sql -f db/seed_comunas.sql
```

Para verificar el aislamiento y las reglas de negocio sobre una base de prueba (el script se revierte al final y no deja datos):

```bash
psql -d paritario -v ON_ERROR_STOP=1 -f db/test_rls.sql
```

Debe terminar con `Todas las verificaciones pasaron.` Son 36 verificaciones; cualquier falla aborta el script con un mensaje `FALLA: …`.

### Cómo funciona el aislamiento

Todas las tablas con datos de clientes tienen Row-Level Security. La aplicación se conecta con un rol que **no** es dueño de las tablas y, al inicio de cada transacción, indica qué usuario está operando:

```sql
SET LOCAL app.usuario_id = '123';
```

A partir de ese valor, la base de datos calcula el ámbito del usuario desde `usuario_rol`:

- **Administrador de empresa / Coordinador / Auditor:** su empresa, o solo su comité en el caso de un coordinador con comité asignado.
- **Administrador / Asesor de organismo:** indicadores de todas las empresas de su organismo (comités, reuniones, actividades, auditorías), **sin** acceso a personas, integrantes ni documentos. El organismo ve datos agregados, no personas.
- **Sin `app.usuario_id`:** no ve nada.

La seguridad por fila separa a los clientes entre sí. **Qué puede editar cada rol** dentro de su ámbito (por ejemplo, que un auditor solo lea) lo controla la API, no la base de datos.

El alta de organismos y empresas se hace con un rol de servicio (dueño), durante la incorporación del cliente.

### Reglas de negocio aplicadas en la base

- RUT con dígito verificador válido (formato `12345678-5`, sin puntos).
- Un solo presidente, un solo secretario y un solo integrante aforado vigentes por comité; el aforado debe ser titular de los trabajadores.
- Un comité de baja necesita fecha de disolución; nunca se borra.
- Una reunión realizada necesita fecha; una actividad cerrada necesita fecha de cierre.
- Cada rol se asigna con un ámbito coherente: los roles de organismo con un organismo, los demás con una empresa, y un comité siempre dentro de su empresa.
- Un subencargado con transferencia internacional de datos necesita salvaguarda declarada.

Las vistas `v_cumplimiento_reuniones` y `v_paridad_comite` calculan el cumplimiento del DS 44 y la paridad de cada comité respetando el ámbito de quien consulta.

### Pendiente en la base de datos

- Confirmar contra la planilla oficial de la SUBDERE la grafía de 5 comunas que difiere entre las fuentes usadas (detalle en la cabecera de `db/seed_comunas.sql`).
- Definir los plazos de `politica_retencion` con asesoría legal.
- Las funciones de ámbito devuelven arreglos de ids; con miles de empresas por organismo conviene revisar su rendimiento con datos reales.
