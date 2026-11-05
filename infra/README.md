# Infraestructura del piloto en AWS

Terraform para el piloto de Paritario (10 empresas) en `sa-east-1` (São Paulo). Está escrita y probada, pero **no se ha aplicado**: se aplica cuando exista la aplicación del MVP.

```
Usuario ─HTTPS─▶ CloudFront ─┬─▶ S3 front (aplicación web)
                             └─/api/*─▶ Lambda "api" (en la VPC) ──▶ RDS PostgreSQL 16
                                             │                 └─▶ S3 documentos
                                             └─ deja trabajos ─▶ S3 operaciones/trabajos/
                                                                     │
                                                                     ▼
                                             Lambda "trabajos" (fuera de la VPC) ─▶ SES (correo)
                                                                                 └─▶ Cognito (usuarios)
```

La API corre en **AWS Lambda**, sin balanceador ni servidores encendidos: solo cobra cuando recibe solicitudes. La aplicación se construye como una imagen de contenedor normal; [Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) traduce las invocaciones a HTTP. Si el tráfico crece, la misma imagen puede correr en ECS Fargate detrás de un balanceador sin cambiar la aplicación.

| Archivo | Qué crea |
| --- | --- |
| `red.tf` | VPC sin NAT Gateway: subredes privadas (base y API) sin salida a internet, con endpoint gratuito hacia S3; subredes públicas solo para la tarea de carga |
| `base_datos.tf` | RDS PostgreSQL 16 privada y cifrada, SSL obligatorio, ingreso con IAM, clave maestra en Secrets Manager |
| `almacenamiento.tf` | Buckets `front`, `documentos` (versionado) y `operaciones` (se vacía a los 7 días), todos privados y solo por TLS |
| `api.tf` | Repositorio ECR y las funciones `api` y `trabajos`, con sus permisos |
| `carga.tf` | Tarea ECS de un solo uso para cargar la base |
| `front.tf` | CloudFront con encabezados de seguridad; `/api/*` va a la función firmando cada solicitud |
| `identidad.tf` | Cognito: usuario = RUT, MFA opcional, altas solo por administrador; inicio de sesión de clientes (SAML u OIDC) |
| `correo.tf` | Identidad de SES con DKIM (si se define `dominio_correo`) |
| `integraciones.tf` | Sincronización diaria de empresas y centros desde los servicios de clientes y organismos |
| `costos.tf` | Presupuesto con alertas por correo |
| `horario.tf` | Encendido y apagado programado de la base (hora de Chile) |

## Requisitos

- Terraform 1.9 o superior y AWS CLI v2.
- Credenciales de un usuario o rol con permisos de administración en la cuenta del piloto, configuradas en su computador (`aws configure` o `aws sso login`). **No las pegue en chats ni las suba al repositorio.**
- La cuenta nueva parte con SES en modo sandbox y con un máximo de 10 ejecuciones simultáneas de Lambda; ver más abajo.

## Aplicar

```bash
cd infra
```

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edite `terraform.tfvars` (al menos `correo_alertas`) y luego:

```bash
terraform init
```

```bash
terraform plan -out piloto.plan
```

```bash
terraform apply piloto.plan
```

La primera vez tarda unos 15 minutos (la base de datos y CloudFront son lo más lento). Sin imagen de la API (`api_imagen = ""`) las funciones no se crean y CloudFront solo sirve el front.

**Estado de Terraform.** Por defecto queda en `infra/terraform.tfstate`, en su computador. No contiene la clave de la base (la gestiona RDS en Secrets Manager), pero sí la configuración completa: no lo suba al repositorio (`.gitignore` ya lo excluye) y respáldelo. Si más de una persona va a aplicar cambios, muévalo a un bucket S3 con versionado agregando un bloque `backend "s3"` en `versions.tf` y ejecutando `terraform init -migrate-state`.

**Protección contra borrado.** La base y el user pool de Cognito tienen protección contra borrado. `terraform destroy` falla hasta desactivarla a mano; es intencional.

## Cargar la base de datos

La base está en subredes privadas. `scripts/cargar_base.sh` sube `db/*.sql` al bucket de operaciones y ejecuta la carga dentro de AWS, como una tarea ECS de un solo uso:

```bash
infra/scripts/cargar_base.sh
```

Crea el esquema y los catálogos (comunas, actividades, códigos SISESAT) y el rol `paritario_app`, con el que se conecta la API: no es dueño de las tablas, no puede saltarse la seguridad por fila y **no tiene clave**. Ingresa con un token de IAM que el SDK de AWS genera en la propia función, válido por 15 minutos. Si la base está apagada por el horario, el script la enciende.

Se puede ejecutar más de una vez: si el esquema ya existe no lo recrea y solo actualiza el rol y sus permisos. Para cambios de esquema posteriores hará falta una herramienta de migraciones en la aplicación.

## Qué necesita la aplicación

La misma imagen sirve para las dos funciones; la variable `MODO` las distingue.

**Imagen.** ARM64, con Lambda Web Adapter copiado en `/opt/extensions/`:

```dockerfile
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter
```

La aplicación escucha en `api_puerto` (8080) y responde 200 en `api_ruta_salud` (`/api/salud`) cuando está lista. Debe arrancar rápido: el primer pedido después de un rato sin uso espera ese arranque (1 a 2 segundos).

**Función `api`** (en la VPC, sin internet):

| Tema | Cómo |
| --- | --- |
| Base de datos | `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`. Con `DB_AUTH=iam`, la clave es un token de `RDS Signer` del SDK. `DB_SSLMODE=verify-full`: incluya en la imagen el [certificado de RDS](https://truststore.pki.rds.amazonaws.com/sa-east-1/sa-east-1-bundle.pem) |
| Conexiones | Una conexión por instancia de la función, abierta fuera del manejador y reutilizada. Cada transacción empieza con `SET LOCAL app.usuario_id` |
| Usuario | El token de Cognito llega en el encabezado **`X-Token-Usuario`**, no en `Authorization` (CloudFront usa ese encabezado para firmar). El emisor está en `COGNITO_EMISOR`; las llaves públicas (`<emisor>/.well-known/jwks.json`) se incluyen en la imagen al construirla, porque la función no tiene internet |
| Cuerpo de POST/PUT/PATCH | El front envía el SHA-256 del cuerpo en el encabezado `x-amz-content-sha256` (exigencia de CloudFront al firmar hacia Lambda) |
| Documentos | Máximo 6 MB por solicitud: los archivos se suben y bajan directo desde el navegador con URL firmadas de S3 (`DOCUMENTOS_BUCKET`) |
| Correo y usuarios | No puede enviar correos ni crear usuarios: deja un JSON en `s3://$OPERACIONES_BUCKET/$TRABAJOS_PREFIJO` |
| Tiempo | Máximo `api_tiempo_max` (29 s) por solicitud |

**Función `trabajos`** (fuera de la VPC, sin acceso a la base): Lambda Web Adapter le entrega cada evento de S3 como un `POST /interno/trabajos`. Lee el JSON, envía el correo (SES, remitente `CORREO_REMITENTE`) o crea, deshabilita o reinicia el usuario en Cognito, y borra el trabajo. Un trabajo fallido queda en el bucket hasta que vence a los 7 días.

**Publicar la API:**

```bash
REPO=$(terraform -chdir=infra output -raw ecr_repositorio)
```

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
```

```bash
docker buildx build --platform linux/arm64 --provenance=false -t "$REPO:v1" --push .
```

Las etiquetas son inmutables: use una nueva en cada versión. Ponga `api_imagen = "<repo>:v1"` en `terraform.tfvars` y aplique.

**Publicar la aplicación web.** Es una aplicación de una página: las rutas sin extensión devuelven `index.html`.

```bash
aws s3 sync dist/ "s3://$(terraform -chdir=infra output -raw bucket_front)" --delete
```

```bash
aws cloudfront create-invalidation --distribution-id "$(terraform -chdir=infra output -raw cloudfront_id)" --paths "/*"
```

**Concurrencia.** Las cuentas nuevas parten con un máximo de 10 ejecuciones simultáneas de Lambda en total, lo que de paso protege a la base pequeña. Si AWS amplía la cuota (Service Quotas → Lambda → *Concurrent executions*), fije `api_concurrencia` (por ejemplo, 20) para que la API nunca abra más conexiones de las que la base aguanta.

## Integraciones con clientes y organismos

Un organismo (marca blanca) o una empresa cliente puede conectar tres servicios suyos. Cada integración se registra en la tabla `integracion` de la base, con su dueño, y queda activa o en prueba.

| Servicio | Quién | Qué hace Paritario |
| --- | --- | --- |
| Inicio de sesión (SSO) | Organismo o empresa | En cada ingreso concilia los accesos: crea los que corresponden y revoca los que ya no vienen |
| Empresas o contratos | Organismo | Cada día crea y actualiza sus empresas, y da de baja los contratos que dejaron de venir |
| Centros de trabajo | Organismo o empresa | Cada día crea y actualiza los centros por contrato, y marca como no vigentes los que dejaron de venir |

Nada se borra: las bajas se marcan. Cada carga queda en la tabla `sincronizacion` con nuevos, actualizados, bajas y errores (sin datos personales). Si más del 10 % de las filas trae errores, no se aplican bajas, para no vaciar un cliente por un listado defectuoso.

**Contrato.** Es el número de adherente o de contrato con que el organismo identifica a cada empresa (`empresa.codigo_contrato`), uno por empresa. Une el SSO con las empresas, y los centros con su empresa.

### Inicio de sesión del cliente

Su sistema (SAML u OIDC) debe enviar en cada ingreso el **RUT**, el **rol** (con su propio código) y, si es un organismo, los **contratos** del usuario. Cada rol externo equivale a uno de los tres roles de empresa: administrador, coordinador o auditor (tabla `rol_externo`). Un rol sin equivalencia no da acceso.

1. Defina un dominio propio (`dominio`): la dirección de retorno `https://<dominio>/auth/callback` se registra en el sistema del cliente.
2. Agregue el proveedor en `terraform.tfvars` y aplique:

```hcl
proveedores_identidad = {
  mutual-a = {
    tipo         = "SAML"
    metadata_url = "https://idp.mutual-a.cl/metadata.xml"
    atributos    = { rut = "rut", rol = "perfil", contratos = "contratos" }
  }
}
```

3. Entregue al cliente los datos de Paritario como proveedor de servicio. Para SAML, la URL de respuesta es `https://<dominio Cognito>/saml2/idpresponse` y el identificador es `urn:amazon:cognito:sp:<cognito_user_pool_id>`. El dominio de Cognito está en la variable `COGNITO_DOMINIO` de la API.
4. Registre la integración en la base (`integracion` de tipo `sso`, con `configuracion = {"proveedor": "mutual-a"}`) y sus equivalencias de rol en `rol_externo`.

En OIDC, `client_secret` queda en el estado de Terraform: protéjalo como se indica en "Estado de Terraform".

### Servicios de empresas y centros

1. Guarde las credenciales del servicio en Secrets Manager, bajo el prefijo de integraciones. La función de trabajos solo puede leer ese prefijo:

```bash
aws secretsmanager create-secret --name "paritario-piloto/integraciones/mutual-a-empresas" --secret-string '{"url": "https://api.mutual-a.cl/adherentes", "token": "…"}'
```

2. Registre la integración en la base: tipo `empresas` o `centros`, `secreto_ref` con el nombre del secreto y estado `activa`.

La sincronización corre a las 07:30, hora de Chile, cuando la base está encendida en cualquier horario. Para probarla a mano:

```bash
aws lambda invoke --function-name "$(terraform -chdir=infra output -raw api_funcion)" --payload '{"tipo":"sincronizar"}' --cli-binary-format raw-in-base64-out /dev/stdout
```

### Qué implementa la aplicación

- **`POST /interno/eventos`** en la API (Lambda Web Adapter entrega ahí los eventos que no son HTTP; CloudFront no expone esa ruta):
  - `{"tipo": "sincronizar"}`: por cada integración activa de empresas o centros, deja un trabajo en `trabajos/`.
  - Evento de S3 en `importaciones/`: lee el JSON y llama a `importar_empresas()` o `importar_centros()` en la base; luego borra el archivo.
- **Función de trabajos**: para un trabajo de sincronización, lee el secreto, consulta el servicio del cliente, convierte la respuesta al formato de la base y la deja en `importaciones/<integracion>/<fecha>.json`.
- **Ingreso por SSO**: si el token de Cognito viene de un proveedor de cliente, la API llama a `sincronizar_accesos_sso()` con `custom:rut`, `custom:rol_externo` y `custom:contratos` antes de atender la solicitud.

Los formatos de entrada están en los comentarios de esas funciones, en `db/schema.sql`.

## Dominio propio (opcional)

Sin dominio, la aplicación queda en `https://xxxx.cloudfront.net` (salida `url`). Para usar un dominio propio:

1. Pida un certificado en ACM **en `us-east-1`** (CloudFront solo usa esa región) para `app.su-dominio.cl` y valídelo por DNS.
2. Defina `dominio` y `certificado_cloudfront_arn` y aplique.
3. Cree en su DNS un CNAME de `app.su-dominio.cl` hacia la salida `cloudfront_dominio`.

## Antes de cargar datos reales

1. **Correo.** Defina `dominio_correo`, publique en el DNS los tres registros CNAME de la salida `dkim_registros` y pida a AWS salir del sandbox de SES (consola de SES → *Request production access*). En sandbox solo se puede enviar a direcciones verificadas.
2. Revise el [anexo de privacidad](../docs/anexo-privacidad.html): contrato de encargo con AWS, registro de actividades y plazos de retención.

Todo el tráfico va cifrado de punta a punta: navegador → CloudFront → función (HTTPS firmado) → base (TLS verificado).

## Horario de encendido

| `horario` | Base encendida |
| --- | --- |
| `siempre` | Todo el tiempo |
| `dias_habiles` | Lunes a viernes, 07:00 a 20:00 |
| `fines_de_semana` | Sábado 07:00 a domingo 23:00 |

Las horas son de Chile (`America/Santiago`, con cambio de horario incluido). La API no necesita horario: no cobra mientras no recibe solicitudes.

- Apagada la base, solo se cobra su almacenamiento y respaldos.
- Fuera de horario la aplicación responde con error; avise a los usuarios del piloto.
- RDS vuelve a encender sola una base que lleva 7 días apagada. Con los dos calendarios nunca pasa más de 6 días apagada.

## Costos

Estimación para `sa-east-1` con la configuración por defecto, con el volumen de un piloto:

| Componente | Siempre encendida | Días hábiles | Fines de semana |
| --- | --- | --- | --- |
| Base de datos (db.t4g.micro + 20 GB) | ~25 USD | ~12 USD | ~9 USD |
| Lambda, CloudFront, S3, Cognito | ~0–2 USD (niveles gratuitos) | igual | igual |
| Secrets Manager, CloudWatch | ~1–2 USD | igual | igual |
| **Total aproximado** | **~28–30 USD/mes** | **~14–16 USD/mes** | **~11–13 USD/mes** |

Lambda incluye cada mes 1 millón de solicitudes y 400.000 GB-segundo gratis; Cognito, 10.000 usuarios activos. No hay IP públicas permanentes, balanceador ni NAT Gateway. Confirme los valores en la [calculadora de AWS](https://calculator.aws/) antes de comprometer un presupuesto.

El presupuesto (`presupuesto_mensual_usd`, 150 por defecto) avisa a `correo_alertas` al llegar al 33 % y al 100 %, y si el pronóstico del mes lo supera. Confirme la suscripción del correo de AWS Budgets.

## Endurecimiento para producción

El piloto deja fuera, a propósito, controles que agregan costo. El análisis con [checkov](https://www.checkov.io/) da 0 fallas: cada regla que no se cumple queda marcada en el código con `#checkov:skip` y su motivo. Las principales:

| Control | Por qué no en el piloto |
| --- | --- |
| WAF en CloudFront | ~10–15 USD/mes |
| Base Multi-AZ (`db_multi_az`) | Duplica el costo de la base |
| Llaves KMS propias (S3, Secrets Manager, CloudWatch, ECR, Lambda) | Se usan las llaves administradas por AWS |
| Firma de código y trazas X-Ray en Lambda | X-Ray necesita salida a internet o un endpoint de pago desde la VPC |
| Rotación automática de la clave maestra | La API no la usa; solo la tarea de carga |
| Registros de acceso (CloudFront, S3) y de flujo de la VPC | Costo de almacenamiento y análisis |
| Performance Insights y monitoreo mejorado de la base | Costo de monitoreo |
| Retención de registros de 1 año | Se guardan 30 días por minimización de datos (Ley 21.719) |
| Replicación entre regiones | Los respaldos de RDS y el versionado de documentos bastan para el piloto |

Para revisar de nuevo:

```bash
checkov -d infra --framework terraform
```

## Pruebas

`tests/piloto.tftest.hcl` prueba la configuración con un proveedor simulado, sin cuenta de AWS ni costo: el piloto sin aplicación, la API en Lambda con horario de días hábiles (red, permisos, variables sin claves, origen de CloudFront, trabajos), el horario de fines de semana, el dominio propio con correo, el inicio de sesión de clientes (SAML y OIDC) y el rechazo de configuraciones inválidas.

```bash
terraform -chdir=infra init -backend=false
```

```bash
terraform -chdir=infra test
```
