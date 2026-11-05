# Paritario — Comités Paritarios de Higiene y Seguridad

Plataforma independiente para que cualquier empresa constituya y gestione sus Comités Paritarios de Higiene y Seguridad (CPHS) según el DS 44/2024: integrantes, comisiones, programa de trabajo, reuniones, actas y certificación.

Funciona en dos modos con la misma instalación:

- **Venta directa** a empresas, sin importar su mutualidad u organismo administrador.
- **Marca blanca** para organismos administradores (mutualidades o servicios públicos) que la entregan a sus empresas adherentes con su propia marca.

Este repositorio contiene, por ahora, el diseño del producto, el esquema de base de datos y la infraestructura del piloto en AWS (escrita y probada, sin aplicar). Todavía no hay código de aplicación.

## Contenido

| Ruta | Qué es |
| --- | --- |
| [`docs/especificacion-funcional.md`](docs/especificacion-funcional.md) | Especificación funcional: módulos, roles, requisitos, cumplimiento, roadmap, costos, comparación de nubes y oferta para organismos |
| [`docs/prototipo.html`](docs/prototipo.html) | Prototipo navegable con datos de ejemplo: perfil de organismo en marca blanca e investigación de accidentes con códigos SISESAT reales |
| [`docs/modelo-datos.html`](docs/modelo-datos.html) | Modelo de datos v5.4: diagrama entidad-relación y las 38 tablas |
| [`docs/anexo-privacidad.html`](docs/anexo-privacidad.html) | Anexo de privacidad según la Ley 21.719 |
| [`docs/arquitectura-aws.html`](docs/arquitectura-aws.html) | Arquitectura de referencia en AWS |
| [`db/schema.sql`](db/schema.sql) | Esquema PostgreSQL 16: 38 tablas, restricciones y seguridad por fila |
| [`db/seed.sql`](db/seed.sql) | Catálogos base: regiones, organismos administradores con su código SUSESO, roles y niveles de certificación generales |
| [`db/seed_comunas.sql`](db/seed_comunas.sql) | Las 346 comunas con su código único territorial (CUT) vigente desde 2018 |
| [`db/seed_actividades.sql`](db/seed_actividades.sql) | Las 21 secciones del CIIU4.CL 2012 y los 674 códigos de actividad económica del SII, verificados contra la tabla oficial de homologación |
| [`db/seed_sisesat.sql`](db/seed_sisesat.sql) | Códigos SISESAT de la SUSESO para investigar accidentes y enfermedades (8.641 códigos): forma (Anexo II), agente material (III), causa externa CIE-10 y equivalencias (IV), naturaleza de la lesión (V), ubicación anatómica (VI) y agentes de enfermedad (IX). Se genera con `db/scripts/generar_seed_sisesat.py` |
| [`db/test_rls.sql`](db/test_rls.sql) | Prueba del aislamiento entre empresas y organismos, y de las reglas de negocio |
| [`infra/`](infra/README.md) | Terraform del piloto en AWS (`sa-east-1`): red, base de datos, API, CloudFront, Cognito, SES, presupuesto y horario de encendido. Incluye el script de carga de la base y pruebas sin cuenta de AWS |

Los archivos HTML se abren directamente en el navegador. El diagrama entidad-relación del modelo de datos carga la librería Mermaid desde cdnjs, así que necesita conexión a internet.

## Base de datos

Requiere PostgreSQL 16 (usa `UNIQUE NULLS NOT DISTINCT`, disponible desde la versión 15).

```bash
createdb paritario
```

```bash
psql -d paritario -v ON_ERROR_STOP=1 -f db/schema.sql -f db/seed.sql -f db/seed_comunas.sql -f db/seed_actividades.sql -f db/seed_sisesat.sql
```

Para verificar el aislamiento y las reglas de negocio sobre una base de prueba (el script se revierte al final y no deja datos):

```bash
psql -d paritario -v ON_ERROR_STOP=1 -f db/test_rls.sql
```

Debe terminar con `Todas las verificaciones pasaron.` Son 70 verificaciones; cualquier falla aborta el script con un mensaje `FALLA: …`.

### Cómo funciona el aislamiento

Todas las tablas con datos de clientes tienen Row-Level Security. La aplicación se conecta con un rol que **no** es dueño de las tablas y, al inicio de cada transacción, indica qué usuario está operando:

```sql
SET LOCAL app.usuario_id = '123';
```

A partir de ese valor, la base de datos calcula el ámbito del usuario desde `usuario_rol`:

- **Administrador de empresa / Coordinador / Auditor:** su empresa, o solo su comité en el caso de un coordinador con comité asignado.
- **Administrador / Asesor de organismo:** indicadores de todas las empresas de su organismo (comités, reuniones, actividades, auditorías), **sin** acceso a personas, integrantes ni documentos. El organismo ve datos agregados, no personas.
- **Sin `app.usuario_id`:** no ve nada.

Las investigaciones de accidentes y enfermedades profesionales contienen datos de salud: solo las ven la empresa y el comité. El organismo ve únicamente los totales de la vista `v_indicadores_siniestralidad` (accidentes, gravedad, días perdidos), sin casos ni personas.

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

- Cargar la CIE-10 cap. I–XVIII (diagnóstico de enfermedades profesionales), que no forma parte de los anexos SISESAT.
- Revisar con la SUSESO las 108 equivalencias del Anexo IV con anomalías (anotadas en `equivalencia_cie10_oit.observacion`): formas o agentes que no existen en las versiones 2018 de los Anexos II y III, una forma marcada con duda (¿34?) y códigos repetidos.
- Revisar con la SUSESO 7 códigos mal formados del Anexo IX (anotados en `codigo_sisesat.observacion`): 6 se normalizaron agregando el cero inicial que faltaba; "Ambiente interior (no industrial)" (21100000000) se conserva tal cual porque no tiene una corrección evidente.
- Confirmar los códigos SUSESO de los organismos administradores (3111 ACHS, 3112 IST, 3113 Mutual de Seguridad) contra el texto vigente del Compendio, y si existe un código para el ISL. Se tomaron de búsquedas sobre el Compendio, sin acceso directo al documento.
- Definir los plazos de `politica_retencion` con asesoría legal.
- Las funciones de ámbito devuelven arreglos de ids; con miles de empresas por organismo conviene revisar su rendimiento con datos reales.
