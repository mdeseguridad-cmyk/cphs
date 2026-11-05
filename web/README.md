# Aplicación web de Paritario (MVP)

Front del MVP: React 18 + TypeScript, compilado con Vite como aplicación de una página. Se publica en S3 detrás de CloudFront y habla con la [API](../api/README.md) en `/api`.

## Pantallas

| Pantalla | Qué permite |
| --- | --- |
| Ingreso | RUT y contraseña (Cognito), clave nueva en el primer ingreso, código MFA, y botones para entrar con el sistema de un cliente u organismo |
| Panel | Comités activos, cumplimiento de reuniones del año, comités no paritarios y actividades atrasadas |
| Comités | Lista con filtro por estado; crear comité (administrador) |
| Comité → Resumen | Datos, paridad por estamento y cumplimiento por año; editar y dar de baja |
| Comité → Integrantes | Agregar (con validación de RUT), cambiar cargo, registrar término, ver históricos |
| Comité → Comisiones | Crear comisiones del DS 44 o propias y asignar integrantes |
| Comité → Programa de trabajo | Crear el programa desde la plantilla del rubro; tablero planificado → en ejecución → cerrado |
| Comité → Reuniones | Cronograma del año (una por mes), registrar realizada o no realizada con su acta, asistencia |
| Comité → Documentos | Subir actas y documentos directo a S3 (con huella SHA-256) y descargarlos |
| Centros de trabajo | Lista, agregar y editar (los sincronizados desde el organismo solo cambian su alias) |
| Usuarios y accesos | Invitar, reenviar invitación, bloquear, desbloquear y quitar accesos (administrador) |

Cada rol ve solo lo que puede hacer: el coordinador no administra usuarios ni otros comités, el auditor solo lee, y el organismo ve sus empresas sin integrantes ni documentos. La API vuelve a validar todo; el front solo esconde lo que no corresponde.

## Cómo cumple lo que exige la infraestructura

- El token de Cognito va en **`X-Token-Usuario`** y cada cuerpo lleva su SHA-256 en **`x-amz-content-sha256`** (`src/api.ts`): CloudFront firma la llamada a la función de la API.
- Los archivos se suben directo a S3 con la URL firmada y la huella que exige la API; nunca pasan por la función.
- La sesión vive en `sessionStorage`: se cierra con la pestaña.
- La configuración (`/config.json`) se lee al cargar: la misma compilación sirve para cualquier entorno.

## Desarrollo

Requiere Node 22, la API corriendo en `localhost:8080` y su base cargada.

```bash
npm ci
```

```bash
npm run dev
```

En desarrollo no se usa Cognito: el servidor de Vite entrega un `config.json` de desarrollo y emite tokens de prueba (`dev/tokens.ts`); basta el RUT de un usuario de la base. Sus llaves públicas quedan en `web/.dev/jwks.json`: inicie la API con

```bash
COGNITO_JWKS_PATH=../web/.dev/jwks.json COGNITO_EMISOR=https://desarrollo.local/paritario COGNITO_CLIENT_ID=paritario-desarrollo DB_HOST=localhost DB_AUTH=clave DB_PASSWORD=… DB_SSLMODE=disable npm --prefix ../api run dev
```

Nada de esto se publica: la compilación no incluye `config.json` ni el emisor de tokens, y la API publicada solo acepta tokens del user pool de Cognito.

## Pruebas

```bash
npm run typecheck
```

```bash
npm run e2e
```

La prueba de punta a punta levanta la API real contra PostgreSQL (la misma base de pruebas de la API, con la seguridad por fila activa), un S3 local que rechaza archivos con otra huella, y recorre la aplicación en Chromium con Playwright: ingreso, comités, integrantes y reglas del DS 44, comisiones, programa, actas, reuniones, usuarios, permisos de coordinador, auditor y organismo, y el teléfono en modo oscuro. Deja capturas en `test/capturas/`.

## Publicar

```bash
web/scripts/publicar.sh
```

Compila, escribe `config.json` con las salidas de Terraform (user pool, cliente, dominio de Cognito y proveedores de clientes), sube los archivos al bucket del front e invalida `index.html` y `config.json` en CloudFront. Para poner nombre a los botones de clientes: `ETIQUETAS='{"mutual-a": "Mutualidad Ejemplo"}'`.

## Pendiente

- Activar MFA desde la aplicación (hoy se puede responder el código, pero no enrolarse).
- Recuperar la contraseña olvidada (Cognito lo permite; falta la pantalla).
- Solicitudes de acceso por autoservicio, investigación de accidentes, auditorías y reportes (fases siguientes, junto con la API).
