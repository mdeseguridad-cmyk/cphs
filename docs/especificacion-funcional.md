# Especificación Funcional · Paritario

> Documento de trabajo, exportado el 5 de noviembre de 2026. Orientación de diseño; las referencias normativas deben validarse con asesoría legal.

## 1. Resumen ejecutivo

Paritario es una plataforma web independiente y multiempresa (SaaS) para que cualquier empresa constituya y gestione sus Comités Paritarios de Higiene y Seguridad (CPHS): conformación, comisiones, programa de trabajo, reuniones, actas y certificación. Funciona igual para empresas de ACHS, Mutual de Seguridad, IST o ISL, sin depender de ninguna, y también se ofrece en marca blanca a organismos administradores que no tengan plataforma propia. Se ofrece como servicio en la nube, de bajo costo operativo, con paridad funcional con las plataformas de las mutualidades y preparada para el DS 44/2024 y la Ley 21.719 de protección de datos.

## 2. Objetivos y alcance

**Objetivos**

- Ofrecer a cualquier empresa, sin importar su mutualidad u organismo administrador, una sola plataforma para gestionar todos sus comités.
- Asegurar y evidenciar el cumplimiento del DS 44 (reuniones, actas, programa de trabajo).
- Dar autoservicio a las empresas, con control de acceso por rol y ámbito.
- Garantizar la seguridad y trazabilidad de los datos personales de los trabajadores.
- Reducir el costo operativo y la dependencia tecnológica (sin licencias Windows/SQL Server).

**Dentro del alcance (versión 1)**

- Empresas cliente y centros de trabajo; comités e integrantes; comisiones; programa de trabajo; reuniones y actas; certificación; accesos y roles; panel y reportes; notificaciones por correo.

**Fuera del alcance (fases posteriores)**

- Aplicación móvil nativa (la v1 entrega una PWA), firma electrónica avanzada de actas, e-learning/capacitación en línea e integraciones con sistemas contables o de RR.HH.

## 3. Actores y roles

El acceso se controla por rol y por ámbito (empresa y/o comité), de modo que ningún usuario ve datos fuera de lo que le corresponde. Hay tres roles en la empresa y dos roles de organismo, que solo existen en el modo marca blanca, más el trabajador como titular de sus datos.

| Rol | Ámbito | Qué puede hacer |
| --- | --- | --- |
| Administrador de organismo | Todas las empresas del organismo (marca blanca) | Configura marca, dominio e integraciones; incorpora empresas; ve reportes consolidados |
| Asesor del organismo | Empresas que tiene asignadas | Acompaña a las empresas en su programa de trabajo; lectura de su avance |
| Administrador de empresa | Toda la empresa | Crea y gestiona comités y centros, aprueba o rechaza accesos, ve todos los reportes; es el único que consulta la bitácora de accesos de su empresa |
| Coordinador de comité | Su(s) comité(s) | Edita integrantes, comisiones, programa de trabajo, reuniones y actas de su comité |
| Auditor | Según asignación | Realiza auditorías y certificación; lectura del resto de la información, salvo la bitácora de accesos |
| Trabajador / titular | Sus propios datos | Consulta su comité y ejerce sus derechos (acceso, rectificación, etc.) |

## 4. Empresas y centros de trabajo

Permite registrar las empresas cliente y sus centros de trabajo, base sobre la que se constituyen los comités.

- Registrar y mantener empresas cliente (RUT, razón social, código de actividad económica del SII, organismo administrador y plan contratado); la sección CIIU de ese código es el rubro y determina la plantilla de programa de trabajo propuesta.
- Registrar el **contrato** de cada empresa: el número de adherente o de contrato con que su organismo la identifica, uno por empresa.
- Administrar centros de trabajo con alias, dirección (región/comuna desde catálogo) y masa de trabajadores.
- Marcar centros como vigentes o no vigentes, sin eliminarlos, para conservar el historial.
- Buscar y filtrar centros por nombre, comuna o estado.
- **Carga automática:** si el organismo o la empresa tiene un servicio de empresas o de centros de trabajo, Paritario los actualiza cada día (sección 20). Los centros sincronizados muestran su código y su origen; los agregados a mano no se tocan.

## 5. Comités e integrantes

Gestiona el ciclo de vida completo de cada comité y de las personas que lo integran.

- Constituir un comité asociado a un centro de trabajo, con su periodo de vigencia (2 años) y fecha de constitución.
- Registrar integrantes titulares y suplentes, con conformación paritaria (igual número de representantes de empresa y de trabajadores).
- Registrar a cada persona una sola vez por su RUT: si ya integra comités de otra empresa (por ejemplo, un contratista), se vincula sin ver ni modificar los datos que cargó esa empresa.
- Designar presidente y secretario, con atribuciones para modificar el comité.
- Marcar al integrante aforado, cuya designación debe constar en el acta de constitución.
- Dar de baja o disolver un comité (estado + fecha), conservando su historial; nunca se elimina físicamente.
- Validar reglas de negocio: paridad, presidente y secretario únicos por periodo.

## 6. Comisiones

Organiza el trabajo del comité en comisiones, cada una responsable de un conjunto de actividades del programa.

- Conformar las comisiones típicas del DS 44: investigación de accidentes y enfermedades profesionales, capacitación y difusión, e inspección y observación.
- Crear comisiones personalizadas según necesidad del comité.
- Asignar integrantes a cada comisión y designar un responsable.
- Vincular las actividades del programa de trabajo a la comisión que las ejecuta.
- Registrar en la comisión de investigación cada accidente o enfermedad profesional: tipo, gravedad, folio de la DIAT o DIEP y codificación SISESAT (en accidentes: forma, agentes materiales, naturaleza y ubicación de la lesión, causa externa CIE-10; en enfermedades: diagnóstico CIE-10 y agente causal), con sus causas inmediatas y básicas y sus medidas correctivas según la prelación del DS 44. Son datos de salud: el organismo solo ve totales, nunca casos ni personas.

## 7. Programa de trabajo

El corazón operativo del sistema: el plan de actividades preventivas del comité, alineado al DS 44.

- Elegir entre un **programa predeterminado por rubro** (actividades propuestas según el rubro de la empresa) o una **configuración manual**.
- Gestionar las actividades en un **tablero Kanban** con estados Planificado, En ejecución y Cerrado.
- Cada actividad define: comisión responsable, responsable (integrante), **frecuencia** (mensual, quincenal, anual, etc.) y **clasificación** (obligatoria por ley o recomendada).
- Desglosar una actividad en **subactividades**.
- Adjuntar **material de apoyo** descargable por actividad (videos, guías, formatos listos para completar) desde una biblioteca reutilizable.
- Filtrar actividades por responsable, comisión, frecuencia o clasificación.

## 8. Reuniones y actas

Registra las reuniones mensuales del comité y sus actas, y calcula el cumplimiento de forma automática.

- Mantener el cronograma mensual con el estado de cada reunión: planificada, realizada o no realizada. El cronograma del año se genera desde el mes de constitución del comité.
- Registrar la asistencia de cada integrante por reunión.
- Cargar el acta de cada sesión (PDF) y el acta de constitución.
- Calcular el **porcentaje de cumplimiento** a partir de las reuniones realizadas vs. exigidas, sin captura manual. Son exigidas las reuniones registradas (realizadas o no) y las de meses ya terminados sin registro, que cuentan como incumplidas y se marcan «sin registrar». Los meses antes de la constitución o después de la disolución no se exigen.
- Según el DS 44, el comité debe reunirse al menos una vez al mes y dejar acta de cada sesión; el sistema evidencia ese cumplimiento y alerta sobre reuniones no realizadas.

## 9. Certificación y auditorías

Registra las auditorías y la certificación de cada comité, sea una evaluación interna de la empresa o la certificación que otorgue su organismo administrador.

- Parametrizar los **niveles de certificación** (p. ej. inicial, intermedio, avanzado) con sus criterios y puntajes.
- Registrar auditorías con auditor, fecha, puntaje y resultado (aprobada / rechazada).
- Asociar el **nivel otorgado** y la **próxima fecha de revisión** a cada comité.
- Adjuntar el informe de auditoría (completo y resumido) y el certificado.
- Alertar sobre comités sin certificación vigente o con revisión próxima a vencer.

## 10. Accesos y autoservicio

Permite que las empresas gestionen sus propios accesos, con aprobación del administrador.

- Iniciar sesión con RUT y contraseña, con segundo factor (MFA) opcional y, si la empresa lo pide, SSO con su propio proveedor de identidad. Las contraseñas las gestiona el servicio de identidad (Cognito): Paritario no guarda ninguna.
- **Inicio de sesión del cliente u organismo, con rol:** su sistema entrega en cada ingreso el RUT, el perfil y los contratos del usuario. Cada perfil equivale a administrador, coordinador o auditor, y el usuario recibe ese rol en las empresas de sus contratos; los accesos que ya no vienen se quitan. Los asignados a mano no se tocan, y una cuenta bloqueada no entra aunque su sistema la autorice.
- **Invitar usuarios:** el administrador ingresa nombre, RUT (validado con dígito verificador), correo, rol y ámbito. La persona recibe un correo con una clave temporal y define la suya en su primer ingreso.
- Enviar una **solicitud de acceso** indicando rol y ámbito (empresa o comité).
- El administrador **aprueba o rechaza** las solicitudes; al aprobar, se genera el acceso con su ámbito.
- Gestionar usuarios y roles vigentes. Cada cuenta está **invitada** (aún no ingresa), **activa** o **bloqueada**; se puede reenviar la invitación, bloquear y desbloquear. Bloquear cierra las sesiones abiertas e impide el ingreso de inmediato. La sesión vive solo en la pestaña del navegador y se cierra al cerrarla. Las cuentas nunca se borran, para conservar quién hizo cada cosa.
- Toda operación sobre datos personales queda en la bitácora de acceso. La bitácora ya está separada por empresa: solo el administrador de cada empresa puede consultar sus entradas, y nadie puede registrar a nombre de otro. El administrador la consulta en la pantalla **Bitácora de accesos**: quién vio, creó o editó qué dato (integrante, asistencia a una reunión o documento) y de qué comité, desde qué IP y navegador, con filtros por fechas, persona, comité y acción, y descarga en CSV. La descarga queda registrada en la misma bitácora.

## 11. Panel, reportes y notificaciones

Entrega la visión consolidada y las notificaciones que mantienen activo el cumplimiento.

- **Panel** con indicadores: comités activos, cumplimiento de reuniones, certificaciones y alertas abiertas.
- **Alertas accionables**: reuniones no realizadas, vigencias por vencer, comités sin certificación.
- **Reportería**: cumplimiento por región o centro, estado de comités, actividades del programa, con exportación.
- **Notificaciones por correo (Amazon SES)**: convocatorias y recordatorios de reuniones, alertas de vencimiento, avisos del flujo de accesos, invitaciones y recuperación de contraseña. Los correos enlazan al sistema y no incluyen datos sensibles en su cuerpo.

## 12. Requisitos no funcionales

| Atributo | Requisito |
| --- | --- |
| Seguridad | Cifrado en tránsito (TLS) y en reposo (KMS); control de acceso por rol y ámbito; MFA; ninguna contraseña en la base (identidad en Cognito, la API entra a la base con tokens de IAM); base de datos y API sin exposición a internet |
| Disponibilidad | Objetivo 99,5% mensual en producción, con base de datos Multi-AZ y failover automático; el piloto usa una sola zona con respaldos diarios |
| Rendimiento | Respuesta < 2 s en operaciones habituales; soporte de uso concurrente de múltiples empresas cliente. En el piloto, la primera solicitud después de un rato sin uso puede tardar 10 a 20 s mientras la API abre su conexión a la base; las siguientes son rápidas |
| Escalabilidad | API sin estado, escalado automático según demanda (Lambda en el piloto; contenedores con balanceador a escala) |
| Usabilidad | Interfaz clara en español, flujos guiados; curva de aprendizaje baja |
| Accesibilidad | Lineamientos WCAG 2.1 AA |
| Soporte móvil | PWA responsiva, acceso por QR; base para app nativa futura |
| Auditoría | Bitácora de quién vio o cambió datos personales, cuándo y desde dónde (IP según CloudFront, que no se puede falsificar, y navegador): integrantes, asistencia, y carga y descarga de documentos. La aplicación agrega entradas pero no puede modificarlas. El administrador de la empresa la consulta y la descarga en CSV, y cada descarga queda registrada |
| Datos de salud | Toda investigación de accidentes o enfermedades se marca como dato sensible, aunque quien la suba no lo indique, y solo la ven la empresa y el comité. La base de datos rechaza una investigación sin esa marca |
| Integridad de documentos | Actas y documentos se suben directo del navegador al almacenamiento, sin pasar por la API; cada archivo queda registrado con su huella SHA-256, su tamaño y su versión, y solo se muestra cuando la carga se confirma |

## 13. Cumplimiento normativo

El sistema se diseña para cumplir el marco de seguridad y salud en el trabajo y el de protección de datos.

- **DS 44/2024** — Reglamento sobre gestión preventiva de los riesgos laborales: programa de trabajo, clasificación de actividades obligatorias y prelación de medidas.
- **Ley 16.744** — marco de los comités paritarios: constitución, conformación y reuniones.
- **Ley 21.719** — protección de datos personales (vigente desde el 1 de diciembre de 2026, con proyecto de postergación a 2027 en trámite): cada empresa cliente como responsable (en marca blanca, también el organismo) y el proveedor como encargado, base de licitud por obligación legal, derechos ARCOP, retención, notificación de brechas, encargados y transferencia internacional. El detalle está en el [Anexo de Privacidad](anexo-privacidad.html).
- **Medidas ya aplicadas en el MVP** — confidencialidad por rol decidida por la base de datos (un comité de otra empresa no aparece), bitácora de accesos a datos personales, con IP y navegador, que no se puede alterar, está separada por empresa y su administrador consulta y descarga, investigaciones marcadas como datos de salud por regla de la base de datos, personas compartidas entre empresas sin exponer sus datos, sesiones acotadas a la pestaña, registros técnicos sin datos personales (sin la IP del visitante ni los valores de las consultas) que se borran a los 30 días, y pruebas solo con datos ficticios. Antes de cargar personas reales falta fijar el plazo de conservación de la bitácora y recorrer el piloto con cada rol. Para producción, la bitácora debe protegerse también frente al administrador técnico de la base, copiándola a un almacenamiento que no admita cambios.

Esta sección es orientación de diseño y debe validarse con asesoría legal.

## 14. Arquitectura y tecnología

Arquitectura desacoplada sobre Linux, con servicios administrados y aislamiento de red por VPC.

- **Front:** SPA en React + TypeScript (implementada para el MVP en `web/`), servida como sitio estático (S3 + CloudFront). Lee su configuración (`config.json`) al cargar, así la misma compilación sirve para cualquier entorno.
- **API:** servicio REST en TypeScript sobre Node 22 (implementado para el MVP en `api/`), empaquetado como imagen de contenedor. Parte en **AWS Lambda** (con Lambda Web Adapter), que cobra solo por solicitud y no necesita balanceador; con tráfico sostenido, la misma imagen pasa a ECS Fargate detrás de un balanceador sin cambiar la aplicación. Las tareas que necesitan internet (correo, alta de usuarios) las hace una segunda función fuera de la red privada, que no tiene acceso a la base.
- **Datos:** PostgreSQL administrado (RDS; Multi-AZ en producción), al que la API entra con tokens de IAM, sin claves guardadas; documentos (actas, informes) en S3 cifrado, subidos y bajados directo desde el navegador con URL firmadas; caché/sesión en Redis (ElastiCache) solo cuando la escala lo justifique. Cada empresa cliente queda aislada en la base de datos con Row-Level Security (ver [`db/schema.sql`](../db/schema.sql)).
- **Identidad:** Cognito (o Entra ID) para autenticación, MFA y roles.
- **Transversales:** Secrets Manager + KMS, CloudWatch/CloudTrail, Amazon SES, EventBridge Scheduler para tareas programadas.

La infraestructura del piloto está escrita en Terraform en [`infra/`](../infra/README.md), probada y lista para aplicar.

**Residencia de datos (decisión crítica):** AWS aún no tiene región en Chile (anunciada para fines de 2026); hoy la más cercana es São Paulo, lo que implica una transferencia internacional bajo la Ley 21.719 y exige salvaguardas, o bien alojar los datos personales en Chile. El detalle está en el [diagrama de arquitectura](arquitectura-aws.html).

## 15. Incorporación de empresas y carga de datos

Cada empresa nueva se incorpora con un proceso guiado; no hay un sistema anterior que migrar.

- Alta de la empresa, sus centros de trabajo y su administrador inicial.
- Carga masiva de comités e integrantes desde una planilla modelo (Excel o CSV), con validación de RUT y de paridad.
- Importación opcional de datos que la empresa exporte de su herramienta actual o de la plataforma de su mutualidad, si esta lo permite.
- Carga de actas y documentos históricos al almacenamiento de objetos.
- Normalización de región y comuna contra los catálogos.

## 16. Plan de fases y roadmap

| Fase | Contenido | Condición para pasar a la siguiente |
| --- | --- | --- |
| 1 · MVP | Comités e integrantes, reuniones y actas | DS 44 operativo |
| 2 · Programa | Programa de trabajo (Kanban), comisiones, material de apoyo | Paridad de mercado |
| 3 · Certificación | Auditorías, autoservicio, panel y reportes | Adopción |
| 4 · Escala | Privacidad 21.719, PWA móvil, nuevos clientes | — |

La entrega avanza por fases. El MVP (fases 1 y 2) cubre el núcleo legal y el programa de trabajo, y se valida con un piloto de 10 empresas. La fase 3 agrega certificación, autoservicio y reportes; la fase 4 completa la privacidad 21.719, la PWA móvil y la apertura a nuevos clientes y a organismos en marca blanca.

**Estado del MVP:** la API (`api/`) y la aplicación web (`web/`) de las fases 1 y 2 están programadas y probadas: verificaciones de la base de datos, pruebas de la API contra PostgreSQL real y una prueba de punta a punta en el navegador con los roles de administrador, coordinador, auditor y organismo. El piloto está desplegado en AWS (región de São Paulo) y el inicio de sesión real con Cognito funciona. Quedan para después del MVP: activar MFA y recuperar la contraseña desde la aplicación, solicitudes de acceso por autoservicio, investigación de accidentes y sincronización por SFTP.

## 17. Supuestos, restricciones y riesgos

**Supuestos**

- Las empresas del piloto entregan los datos de sus comités en la planilla modelo de carga.
- Cada empresa cliente firma con el proveedor un contrato de encargo (DPA) antes de cargar datos.

**Restricciones**

- La fecha de vigencia de la Ley 21.719 (1 de diciembre de 2026, con posible postergación) condiciona los plazos.
- La decisión de residencia de datos (Chile vs. región AWS) debe tomarse antes de fijar la infraestructura.

**Riesgos**

| Riesgo | Mitigación |
| --- | --- |
| Transferencia internacional de datos personales | Definir residencia en Chile o aplicar salvaguardas (cláusulas tipo) |
| Las mutualidades ofrecen su propia plataforma sin costo a sus empresas | Diferenciar por independencia, uso con cualquier organismo administrador y facilidad de uso |
| Calidad de los datos que cargan los clientes | Validaciones en la carga masiva (RUT, paridad, catálogos) |
| Baja adopción de usuarios | Autoservicio, UX simple, capacitación y material de apoyo |

## 18. Costos de infraestructura

Estimación del costo recurrente de la infraestructura en AWS (región São Paulo, uso moderado, con todas las empresas cliente en una sola instalación). Son valores de dimensionamiento, no una cotización; el costo real depende del tamaño de la base de datos y del tráfico.

| Servicio | Rol | USD/mes |
| --- | --- | --- |
| ECS Fargate | API en contenedores (2 tareas 24/7) | 60 – 110 |
| RDS PostgreSQL | Base de datos Multi-AZ | 150 – 350 |
| ElastiCache Redis | Caché y sesión | 30 – 60 |
| Application Load Balancer | Balanceador | 20 – 30 |
| NAT Gateway | Salida controlada | 35 – 70 |
| S3 + CloudFront | SPA y documentos | 15 – 50 |
| Cognito | Identidad | 0 (gratis hasta ~50 mil usuarios activos) |
| Amazon SES | Correos | < 5 |
| Secrets / KMS / CloudWatch / CloudTrail | Seguridad y observabilidad | 20 – 50 |
| Transferencia de datos | Salida de red | 10 – 30 |
| **Total producción** | | **≈ 350 – 800** |

La producción a escala usa contenedores en ECS Fargate con balanceador: con tráfico sostenido sale más barato y predecible que Lambda. El piloto parte en Lambda (ver abajo) y migra con la misma imagen cuando el uso lo justifique.

- **Staging / pruebas:** un ambiente reducido suma ≈ 120 – 250 USD/mes, o se apaga fuera de horario para ahorrar.
- **Palancas de ahorro:** instancias `t4g` (Graviton), Fargate Spot para tareas no críticas, un solo NAT Gateway y Savings Plans (1–3 años) reducen la factura un 20–40%.
- **Ahorro estructural:** el stack Linux + PostgreSQL evita las licencias de Windows Server y SQL Server, que en modo License Included pueden duplicar el costo de la base de datos.
- **Residencia de datos:** São Paulo encarece ~20–40% frente a EE.UU.; si por la Ley 21.719 se aloja en Chile, el costo sigue la tarifa del proveedor local, no la de AWS.

### Escenario piloto: MVP con 10 empresas

Un piloto de 10 empresas cuesta ≈ 28 – 38 USD/mes en AWS (São Paulo, single-AZ, sin Redis), con la API en Lambda. Volumen supuesto: ~30–50 comités, ~400–600 integrantes, ~50–80 usuarios con acceso, ~30–50 actas y ~1.000–2.000 correos al mes.

| Servicio | Configuración piloto | USD/mes |
| --- | --- | --- |
| RDS PostgreSQL | db.t4g.micro, single-AZ, 20 GB | 25 – 28 |
| AWS Lambda | API y trabajos; 1 millón de solicitudes y 400.000 GB-s gratis al mes | 0 – 2 |
| S3 + CloudFront | SPA y actas (pocos GB) | 0 – 3 |
| Cognito | ~80 usuarios | 0 |
| Amazon SES | ~1.000–2.000 correos | < 1 |
| Secrets Manager / CloudWatch | clave maestra de la base, registros 30 días (también el de la base de datos) | 1 – 3 |
| Transferencia de datos | red | 0 – 2 |
| **Total piloto (24/7)** | | **≈ 28 – 38** |

- **Sin balanceador, NAT Gateway ni IP públicas permanentes.** Son los cargos fijos que más pesan en un piloto (~40–60 USD/mes entre los tres). La API corre en Lambda, en una red privada sin salida a internet; llega a S3 por un endpoint gratuito.
- **La base de datos es casi todo el costo.** El resto se cobra por uso y, con el volumen de 10 empresas, queda en los niveles gratuitos.
- **Costo de la elección:** la primera solicitud después de un rato sin uso tarda 1–2 segundos más (arranque en frío), cada solicitud admite hasta 6 MB y 29 segundos, y las conexiones a la base se limitan con la concurrencia de Lambda. Para un piloto son aceptables.
- Una cuenta AWS nueva tiene Free Tier por 12 meses, que cubre parte de RDS, S3 y transferencia.

### Alternativa: encendido programado

Como la API no cobra mientras no recibe solicitudes, el horario solo enciende y apaga la base de datos. La infraestructura lo trae configurado (`horario` en Terraform, con EventBridge Scheduler en hora de Chile).

| Horario | Base encendida | USD/mes |
| --- | --- | --- |
| Siempre | 24/7 | ≈ 28 – 38 |
| Días hábiles | lunes a viernes, 07:00 a 20:00 | ≈ 14 – 22 |
| Fines de semana | sábado 07:00 a domingo 23:00 | ≈ 11 – 18 |

Condiciones para que funcione:

- **Lo que se sigue cobrando:** con la base detenida se paga su almacenamiento y respaldos; el resto es por uso.
- **Sin acceso fuera de horario:** la aplicación responde con error cuando la base está apagada; hay que comunicarlo a las empresas del piloto.
- **Correos y alertas:** los enlaces de los correos solo funcionan cuando el sistema está encendido.
- **Tiempo de arranque:** RDS tarda ~10–15 minutos en iniciar; el encendido está programado antes del horario de uso.
- **Límite de RDS:** AWS reinicia sola una base detenida tras 7 días seguidos; con los dos calendarios nunca pasa más de 6 días apagada.
- **Datos intactos:** apagar no borra información; base de datos, actas y respaldos se conservan.

## 19. Comparación de nube (AWS / Azure / GCP)

La arquitectura es portable entre los tres proveedores (cada servicio tiene equivalente directo), así que el criterio de elección para este sistema no es técnico, sino de **residencia de datos** (Ley 21.719), **afinidad con .NET** y **correo transaccional**.

**Región en Chile — factor decisivo**

- **Azure (Chile Central):** operativa desde 2025; único hiperescalador con región viva en Chile hoy, lo que permite alojar los datos personales en el país sin transferencia internacional.
- **AWS:** región en Chile anunciada para fines de 2026; mientras tanto, São Paulo o Local Zones en Santiago.
- **Google Cloud:** región de Santiago anunciada, con trabas regulatorias; conviene confirmar su estado operativo.

**Servicios equivalentes**

| Capa | AWS | Azure | Google Cloud |
| --- | --- | --- | --- |
| API en contenedores | Lambda (piloto) / ECS Fargate | Container Apps / AKS | Cloud Run / GKE |
| Base de datos | RDS PostgreSQL | Azure DB for PostgreSQL | Cloud SQL |
| Hosting .NET en Windows (si se requiere) | EC2 Windows / Beanstalk | App Service (Windows) | Compute Engine |
| Almacenamiento | S3 | Blob Storage | Cloud Storage |
| CDN | CloudFront | Front Door | Cloud CDN |
| Identidad | Cognito | Entra ID (AD B2C) | Identity Platform |
| Correo transaccional | SES | Communication Services | — (SendGrid / terceros) |
| Caché | ElastiCache | Azure Cache for Redis | Memorystore |
| Secretos | Secrets Manager | Key Vault | Secret Manager |

**Comparación para el proyecto**

| Criterio | AWS | Azure | GCP |
| --- | --- | --- | --- |
| Región en Chile (21.719) | Prevista fin 2026 | Sí, operativa hoy | Anunciada, a confirmar |
| Afinidad .NET / Microsoft | Buena | Excelente | Buena |
| Correo nativo | Sí (SES) | Sí (ACS) | No (terceros) |
| Madurez / amplitud | Muy alta | Alta | Alta (fuerte en datos) |
| Costo | Competitivo | Competitivo | A veces menor en compute |

**Recomendación**

Para este sistema — datos personales de trabajadores de varias empresas y Ley 21.719 — **Azure es hoy la opción más fuerte**: tiene región en Chile operativa (resuelve la residencia de datos sin transferencia internacional) y es el entorno más natural para .NET, útil si el equipo desarrolla en .NET Core. **AWS** es excelente técnicamente, pero para residencia en Chile hay que esperar su región (fines de 2026) o usar São Paulo con salvaguardas. **GCP** es viable, pero suma dos fricciones: sin correo transaccional nativo y estado incierto de su región en Chile. La decisión final de residencia y proveedor debe validarse con asesoría legal.

*Datos de regiones tomados de fuentes secundarias recientes ([AWS Chile fin 2026](https://www.datacenterdynamics.com/en/news/amazon-to-invest-4bn-in-chile-data-center-region/), [Azure Chile Central](https://blog.elitecenter.cl/blog/azure-chile-central-vs-aws-chile-region-residencia-datos-2026/)); verificar en las páginas oficiales de cada proveedor antes de decidir.*

## 20. Oferta para organismos administradores (marca blanca)

La misma plataforma se ofrece a organismos administradores sin plataforma propia de comités (mutualidades o servicios públicos), para que la entreguen a sus empresas adherentes con su marca. No es una copia del sistema por cliente: es una configuración dentro de la misma instalación.

**Qué recibe el organismo**

- Plataforma con su nombre, logo, colores, dominio y remitente de correos.
- Vista consolidada de todas sus empresas: cumplimiento de reuniones, programa de trabajo y certificación.
- Sus propias plantillas por rubro, material de apoyo y programa de certificación, además del contenido general.
- Roles de Administrador de organismo y Asesor del organismo.

**Integraciones con sus sistemas**

Disponibles para organismos y, salvo el listado de empresas, también para una empresa cliente directa con sistemas propios.

| Integración | Para qué | Quién | Protocolo |
| --- | --- | --- | --- |
| Inicio de sesión (SSO) con rol | Que sus usuarios entren con su cuenta y reciban su rol (administrador, coordinador o auditor) en las empresas de sus contratos | Organismo o empresa | SAML u OIDC |
| Empresas o contratos | Incorporar, actualizar y dar de baja empresas cada día, por número de adherente o contrato | Organismo | API o SFTP |
| Centros de trabajo | Mantener los centros de cada empresa o contrato | Organismo o empresa | API o SFTP |
| Certificación | Intercambiar resultados con su programa propio | Organismo | API |

Las cargas nunca borran: marcan bajas, y no aplican bajas si más del 10 % del listado trae errores. Cada carga queda registrada (nuevos, actualizados, bajas y errores) y se ve en "Marca e integraciones". Las credenciales de sus servicios se guardan en la bóveda de secretos, nunca en la base de datos.

**Cómo se contrata**

| Tipo de organismo | Contratación | Exigencias típicas |
| --- | --- | --- |
| Mutualidad (corporación privada, fiscalizada por SUSESO) | Negociación comercial directa | Revisión de seguridad, DPA, niveles de servicio |
| Servicio público | Ley de Compras Públicas (licitación, convenio marco o trato directo acotado) | Ciberseguridad, residencia de datos en Chile, posible instalación dedicada |

**Modelo de cobro sugerido**

- Pago único de implementación: configuración de marca, integraciones y carga inicial.
- Licencia anual por tramo de empresas adherentes activas en la plataforma.

**Puesta en marcha**

1. Piloto con 10–20 empresas del organismo.
2. Integración del inicio de sesión con rol, del listado de empresas o contratos y de los centros de trabajo.
3. Despliegue gradual al resto de sus empresas.

**Infraestructura a escala:** un organismo con miles de empresas adherentes usa la configuración de producción completa (Multi-AZ, Redis, más capacidad). La estimación es del orden de 900 – 1.800 USD/mes, menos de 0,40 USD al mes por empresa activa. Es un valor de dimensionamiento que depende del número de usuarios activos y de documentos.

**Antes de ofrecerlo:** confirmar directamente con cada organismo que no tenga una plataforma propia en desarrollo.

## 21. Referencias y anexos

Material complementario de este repositorio:

- [Prototipo navegable del sistema](prototipo.html)
- [Modelo de datos detallado (38 entidades)](modelo-datos.html)
- [Anexo de privacidad · Ley 21.719](anexo-privacidad.html)
- [Diagrama de arquitectura AWS](arquitectura-aws.html)
- [Esquema de base de datos (PostgreSQL)](../db/schema.sql)

Referencias normativas: DS 44/2024 (gestión preventiva de riesgos laborales), Ley 16.744 (seguro social de accidentes del trabajo), Ley 21.719 y Ley 19.628 (protección de datos personales).
