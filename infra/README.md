# Infraestructura del piloto en AWS

Terraform para el piloto de Paritario (10 empresas) en `sa-east-1` (São Paulo), según [`docs/arquitectura-aws.html`](../docs/arquitectura-aws.html). Está escrita y probada, pero **no se ha aplicado**: se aplica cuando exista la aplicación del MVP.

```
Usuario ─HTTPS─▶ CloudFront ─┬─▶ S3 front (aplicación web)
                             └─/api/*─▶ Balanceador ─▶ ECS Fargate (API) ─▶ RDS PostgreSQL 16
                                                            ├─▶ S3 documentos
                                                            ├─▶ Cognito (usuarios por RUT)
                                                            └─▶ SES (correo)
```

| Archivo | Qué crea |
| --- | --- |
| `red.tf` | VPC con 2 subredes públicas y 2 privadas, sin NAT Gateway; grupos de seguridad |
| `base_datos.tf` | RDS PostgreSQL 16 privada y cifrada, SSL obligatorio, clave maestra en Secrets Manager, secreto del rol `paritario_app` |
| `almacenamiento.tf` | Buckets `front`, `documentos` (versionado) y `operaciones` (se vacía a los 7 días), todos privados y solo por TLS |
| `api.tf` | Repositorio ECR, clúster y servicio ECS (ARM64), balanceador, tarea de carga de la base |
| `front.tf` | CloudFront con encabezados de seguridad; `/api/*` va al balanceador con un encabezado secreto |
| `identidad.tf` | Cognito: usuario = RUT, MFA opcional, altas solo por administrador |
| `correo.tf` | Identidad de SES con DKIM (si se define `dominio_correo`) |
| `costos.tf` | Presupuesto con alertas por correo |
| `horario.tf` | Encendido y apagado programado (hora de Chile) |

## Requisitos

- Terraform 1.9 o superior y AWS CLI v2.
- Credenciales de un usuario o rol con permisos de administración en la cuenta del piloto, configuradas en su computador (`aws configure` o `aws sso login`). **No las pegue en chats ni las suba al repositorio.**
- La cuenta nueva parte con SES en modo sandbox y con cuotas bajas de Fargate; ver más abajo.

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

La primera vez tarda unos 15 minutos (la base de datos y CloudFront son lo más lento). Sin imagen de la API (`api_imagen = ""`) el servicio queda creado con 0 tareas: no cobra cómputo.

**Estado de Terraform.** Por defecto queda en `infra/terraform.tfstate`, en su computador. Contiene datos sensibles (la clave de `paritario_app`, el encabezado secreto): no lo suba al repositorio (`.gitignore` ya lo excluye) y respáldelo. Si más de una persona va a aplicar cambios, muévalo a un bucket S3 con versionado agregando un bloque `backend "s3"` en `versions.tf` y ejecutando `terraform init -migrate-state`.

**Protección contra borrado.** La base, el user pool de Cognito y el balanceador tienen protección contra borrado. `terraform destroy` falla hasta desactivarla a mano; es intencional.

## Cargar la base de datos

La base está en subredes privadas. `scripts/cargar_base.sh` sube `db/*.sql` al bucket de operaciones y ejecuta la carga dentro de AWS, como una tarea ECS de un solo uso:

```bash
infra/scripts/cargar_base.sh
```

Crea el esquema y los catálogos (comunas, actividades, códigos SISESAT) y el rol `paritario_app`, con el que se conecta la API: no es dueño de las tablas y no puede saltarse la seguridad por fila. Su clave está en el secreto `db_secreto_app_arn`. Si la base está apagada por el horario, el script la enciende.

Se puede ejecutar más de una vez: si el esquema ya existe no lo recrea y solo actualiza el rol y sus permisos. Para cambios de esquema posteriores hará falta una herramienta de migraciones en la aplicación.

## Publicar la aplicación

**API.** La imagen debe ser ARM64, escuchar en el puerto `api_puerto` (8080) y responder 200 en `api_ruta_salud` (`/api/salud`). Recibe la conexión a la base por variables de entorno (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, conexión con `sslmode=require`), además de `DOCUMENTOS_BUCKET`, `COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID` y `CORREO_REMITENTE`. El sistema de archivos del contenedor es de solo lectura.

```bash
REPO=$(terraform -chdir=infra output -raw ecr_repositorio)
```

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
```

```bash
docker buildx build --platform linux/arm64 -t "$REPO:v1" --push .
```

Las etiquetas del repositorio son inmutables: use una nueva en cada versión. Luego ponga `api_imagen = "<repo>:v1"` en `terraform.tfvars` y aplique; ECS reemplaza las tareas sin cortar el servicio.

**Aplicación web.** Es una aplicación de una página: las rutas sin extensión devuelven `index.html`.

```bash
aws s3 sync dist/ "s3://$(terraform -chdir=infra output -raw bucket_front)" --delete
```

```bash
aws cloudfront create-invalidation --distribution-id "$(terraform -chdir=infra output -raw cloudfront_id)" --paths "/*"
```

## Dominio propio (opcional)

Sin dominio, la aplicación queda en `https://xxxx.cloudfront.net` (salida `url`). Para usar un dominio propio:

1. Pida un certificado en ACM **en `us-east-1`** (CloudFront solo usa esa región) para `app.su-dominio.cl` y valídelo por DNS.
2. Defina `dominio` y `certificado_cloudfront_arn` y aplique.
3. Cree en su DNS un CNAME de `app.su-dominio.cl` hacia la salida `cloudfront_dominio`.

## Antes de cargar datos reales

El piloto puede partir con datos de prueba. Antes de cargar personas reales:

1. **Cifrar el tramo CloudFront → balanceador.** Sin certificado de origen, ese tramo va por HTTP dentro de la red de AWS, protegido solo por un encabezado secreto. Pida un certificado en ACM **en `sa-east-1`** para un nombre como `origen.app.su-dominio.cl`, cree un CNAME de ese nombre hacia el balanceador (`aws elbv2 describe-load-balancers`), defina `dominio_origen` y `certificado_alb_arn` y aplique. El balanceador pasa a aceptar solo HTTPS en el puerto 443.
2. **Correo.** Defina `dominio_correo`, publique en el DNS los tres registros CNAME de la salida `dkim_registros` y pida a AWS salir del sandbox de SES (consola de SES → *Request production access*). En sandbox solo se puede enviar a direcciones verificadas.
3. Revise el [anexo de privacidad](../docs/anexo-privacidad.html): contrato de encargo con AWS, registro de actividades y plazos de retención.

## Horario de encendido

| `horario` | Base y API encendidas |
| --- | --- |
| `siempre` | Todo el tiempo |
| `dias_habiles` | Lunes a viernes, 07:00 a 19:45 |
| `fines_de_semana` | Sábado 07:00 a domingo 23:15 |

Todas las horas son de Chile (`America/Santiago`, con cambio de horario incluido). La API se enciende 30 minutos después que la base y se apaga 15 minutos antes.

Tenga en cuenta:

- **Lo que sigue cobrando apagado:** el balanceador y sus IP públicas, el almacenamiento y los respaldos de la base. El horario ahorra el cómputo de la base y de la API, no el balanceador.
- RDS vuelve a encender sola una base que lleva 7 días apagada. Con los dos calendarios nunca pasa más de 6 días apagada.
- Si aplica cambios en horario apagado, Terraform deja la API encendida hasta el siguiente apagado programado.
- Fuera de horario la aplicación responde con error; avise a los usuarios del piloto.

## Costos

Estimación para `sa-east-1` con la configuración por defecto, siempre encendido: unos **65 a 75 USD al mes**. Lo principal es la base de datos (db.t4g.micro, ~25 USD con almacenamiento), el balanceador (~18 USD), las IP públicas (~11 USD) y la API en Fargate (~8 USD). CloudFront, S3, Cognito (hasta 10.000 usuarios activos al mes), Secrets Manager y CloudWatch suman unos pocos dólares con el volumen del piloto. Confirme los valores en la [calculadora de AWS](https://calculator.aws/) antes de comprometer un presupuesto.

El presupuesto (`presupuesto_mensual_usd`, 150 por defecto) avisa a `correo_alertas` al llegar al 33 % y al 100 %, y si el pronóstico del mes lo supera. Confirme la suscripción del correo de AWS Budgets.

## Endurecimiento para producción

El piloto deja fuera, a propósito, controles que agregan costo. El análisis con [checkov](https://www.checkov.io/) da 0 fallas: cada regla que no se cumple queda marcada en el código con `#checkov:skip` y su motivo. Las principales:

| Control | Por qué no en el piloto |
| --- | --- |
| WAF en CloudFront | ~10–15 USD/mes; el balanceador solo admite CloudFront |
| Base Multi-AZ (`db_multi_az`) | Duplica el costo de la base |
| NAT Gateway (tareas sin IP pública) | ~35 USD/mes; las tareas solo admiten tráfico del balanceador |
| Llaves KMS propias (S3, Secrets Manager, CloudWatch, ECR) | Se usan las llaves administradas por AWS |
| Rotación automática de secretos | Requiere una función Lambda de rotación |
| Registros de acceso (CloudFront, balanceador, S3) y de flujo de la VPC | Costo de almacenamiento y análisis |
| Performance Insights, monitoreo mejorado, Container Insights | Costo de monitoreo |
| Retención de registros de 1 año | Se guardan 30 días por minimización de datos (Ley 21.719) |
| Replicación entre regiones | Los respaldos de RDS y el versionado de documentos bastan para el piloto |

Para revisar de nuevo:

```bash
checkov -d infra --framework terraform
```

## Pruebas

`tests/piloto.tftest.hcl` prueba la configuración con proveedores simulados, sin cuenta de AWS ni costo: el piloto sin aplicación, el horario de días hábiles y de fines de semana, el dominio propio con correo, el origen cifrado y el rechazo de configuraciones inválidas.

```bash
terraform -chdir=infra init -backend=false
```

```bash
terraform -chdir=infra test
```
