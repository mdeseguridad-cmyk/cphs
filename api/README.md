# API de Paritario (MVP)

API REST del MVP (fases 1 y 2): empresas y centros de trabajo, comités e integrantes, comisiones, programa de trabajo, reuniones, actas y documentos, usuarios, y las integraciones con clientes y organismos. TypeScript sobre Node 22, con Fastify y PostgreSQL.

La misma imagen corre en Lambda (con [Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter)) y fuera de ella. En el piloto son dos funciones (ver [`infra/`](../infra/README.md)):

| Función | `MODO` | Qué atiende |
| --- | --- | --- |
| `api` | `api` | `/api/*` desde CloudFront, y `/interno/eventos` (programación diaria e importaciones desde S3) |
| `trabajos` | `trabajos` | `/interno/trabajos`: correos, cuentas de Cognito y consulta de servicios de clientes. No llega a la base |

## Cómo protege los datos

- **Seguridad por fila.** La API entra a la base como `paritario_app`, que no es dueño de las tablas. Cada solicitud es una transacción que fija `app.usuario_id`: la base decide qué filas ve cada usuario. Un comité de otra empresa responde 404, sin revelar que existe.
- **Permisos por rol** (`src/permisos.ts`). La base decide qué se ve; la API decide qué se cambia:

| Rol | Puede modificar |
| --- | --- |
| Administrador de empresa | Todo en su empresa: centros, comités, integrantes, programa, reuniones, documentos y usuarios |
| Coordinador | Integrantes, comisiones, programa, reuniones y actas de su comité (o de todos, si no tiene uno asignado) |
| Auditor | Nada (solo lectura; las auditorías son de la fase 3) |
| Administrador o asesor de organismo | Nada (ve indicadores de sus empresas, sin personas) |

- **Sin claves guardadas.** Los usuarios entran con Cognito; la API valida el token con las llaves públicas del user pool, incluidas en la imagen. La base se usa con tokens de IAM.
- **Bitácora.** Ver o cambiar integrantes, asistencia y documentos queda en `log_acceso` (Ley 21.719). El administrador de la empresa la consulta en `GET /api/empresas/:id/bitacora` (filtros `desde`, `hasta`, `usuario_id`, `comite_id`, `accion`; páginas con `antes`) y la descarga en `GET /api/empresas/:id/bitacora.csv`; la descarga queda registrada como `exportar`.
- **Nada se borra.** Comités, integrantes, accesos y cuentas se dan de baja o se bloquean. La única excepción son los miembros de una comisión, que se reemplazan al editarla.

## Autenticación

El front envía el token de identidad de Cognito (id token) en **`X-Token-Usuario`**: CloudFront usa `Authorization` para firmar su llamada a la función. En desarrollo también se acepta `Authorization: Bearer`.

En el primer uso de cada token, la API registra el ingreso:

- **Cuenta de Paritario:** une la cuenta de Cognito con el usuario por su RUT (`registrar_ingreso`) y lo deja activo.
- **Sistema de un cliente (SSO):** concilia los accesos que entrega ese sistema (`ingresar_sso`): rol según su perfil, en las empresas de sus contratos.

Una cuenta bloqueada no entra, aunque su token siga vigente.

## Rutas

| Método | Ruta | Quién |
| --- | --- | --- |
| GET | `/api/salud` | Público (no toca la base) |
| GET | `/api/yo` | Usuario y sus accesos |
| GET | `/api/empresas`, `/api/empresas/:id` | Según ámbito |
| GET, POST | `/api/empresas/:id/centros` | Ver: ámbito · Crear: administrador |
| PATCH | `/api/centros/:id` | Administrador (un centro sincronizado solo cambia su alias) |
| GET | `/api/indicadores?anio=` | Cumplimiento de reuniones, paridad y actividades atrasadas por comité |
| GET | `/api/catalogos/comunas` | Todos |
| GET, POST | `/api/comites` | Ver: ámbito · Crear: administrador |
| GET, PATCH | `/api/comites/:id` | Ver: ámbito · Editar: administrador o coordinador |
| POST | `/api/comites/:id/baja` | Administrador |
| GET, POST | `/api/comites/:id/integrantes` | Ver: empresa · Agregar: administrador o coordinador |
| PATCH | `/api/integrantes/:id` · POST `/api/integrantes/:id/termino` | Administrador o coordinador |
| GET, POST | `/api/comites/:id/comisiones` · PUT `/api/comisiones/:id/integrantes` | Ídem |
| GET | `/api/plantillas?seccion=` · `/api/plantillas/:id/actividades` | Todos |
| POST | `/api/comites/:id/programa` | Instancia el programa desde una plantilla |
| GET, POST | `/api/comites/:id/actividades` · PATCH `/api/actividades/:id` | Kanban: planificado → en_ejecucion → cerrado |
| GET, POST | `/api/comites/:id/reuniones` · POST `/api/comites/:id/cronograma` | Una reunión por mes (DS 44) |
| PATCH | `/api/reuniones/:id` | Realizada exige fecha; el acta debe estar disponible |
| GET, PUT | `/api/reuniones/:id/asistencia` | Solo integrantes del comité |
| GET, POST | `/api/comites/:id/documentos` | Registro pendiente + URL de subida firmada |
| POST | `/api/documentos/:id/confirmar` | Verifica tamaño y SHA-256 en S3 |
| GET | `/api/documentos/:id/descarga` | URL firmada por 5 minutos |
| GET, POST | `/api/empresas/:id/usuarios` | Administrador: lista e invita |
| POST | `/api/usuarios/:id/reenviar` · `bloquear` · `desbloquear` | Administrador de todas las empresas de la persona |
| DELETE | `/api/accesos/:id` | Administrador (no los que entrega el SSO del cliente) |

Errores: `401` sin sesión, `403` sin permiso, `404` no existe o fuera de su ámbito, `409` conflicto, `422` datos inválidos o regla de negocio (con `detalle`).

## Documentos

El navegador sube y baja los archivos directo a S3; la API solo registra y firma:

1. `POST /api/comites/:id/documentos` con tipo, nombre, MIME, tamaño y **SHA-256** del archivo. Responde la URL y los encabezados del `PUT`.
2. El navegador hace el `PUT` con esos encabezados. S3 rechaza un archivo con otra huella.
3. `POST /api/documentos/:id/confirmar`: la API comprueba tamaño y huella en S3, guarda la versión del objeto y lo deja disponible.

Máximo 25 MB; PDF, JPG, PNG o DOCX. Las investigaciones siempre se marcan con datos sensibles.

## Desarrollo

Requiere Node 22 y PostgreSQL 16.

```bash
npm ci
```

```bash
npm test
```

Las pruebas crean una base `paritario_api_prueba` desde cero con el script de carga real (`infra/scripts/carga/cargar.sh`) y la seguridad por fila activa, firman tokens con claves de prueba y reemplazan S3, Cognito, SES y Secrets Manager por versiones en memoria. Usan `PGTEST_HOST`, `PGTEST_PORT`, `PGTEST_USER` y `PGTEST_PASSWORD` (un usuario que pueda crear bases); si no hay base, se omiten.

Para correrla en local contra una base cargada:

```bash
DB_HOST=localhost DB_AUTH=clave DB_PASSWORD=… DB_SSLMODE=disable COGNITO_JWKS_PATH=./jwks.json COGNITO_EMISOR=… COGNITO_CLIENT_ID=… npm run dev
```

## Publicar

```bash
api/scripts/publicar.sh
```

Construye la imagen ARM64 con las llaves públicas del user pool y los certificados de RDS, la sube a ECR e indica el valor de `api_imagen` para `infra/terraform.tfvars`. Después: `terraform apply`.

## Pendiente para las fases siguientes

- Solicitudes de acceso por autoservicio (las tablas existen; faltan las rutas).
- Investigación de accidentes con códigos SISESAT (el prototipo ya tiene la pantalla).
- Auditorías y certificación, reportes exportables, derechos ARCOP.
- Correos de recordatorio de reuniones y vencimientos (la función de trabajos ya envía correos).
- Sincronización por SFTP (hoy solo API REST).
