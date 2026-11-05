variable "proyecto" {
  description = "Nombre corto del proyecto; prefijo de todos los recursos."
  type        = string
  default     = "paritario"
}

variable "entorno" {
  description = "Entorno: piloto, staging o produccion."
  type        = string
  default     = "piloto"
}

variable "region" {
  description = "Región de AWS. sa-east-1 es São Paulo (transferencia internacional de datos: ver anexo de privacidad)."
  type        = string
  default     = "sa-east-1"
}

variable "correo_alertas" {
  description = "Correo que recibe las alertas de presupuesto. Vacío = sin alertas."
  type        = string
  default     = ""
}

variable "presupuesto_mensual_usd" {
  description = "Presupuesto mensual en USD. Se avisa al 33 % y al 100 % del gasto real, y si el pronóstico supera el 100 %."
  type        = number
  default     = 150
}

# --- Red -----------------------------------------------------------------

variable "cidr_vpc" {
  description = "Rango de direcciones de la VPC."
  type        = string
  default     = "10.20.0.0/16"
}

# --- Base de datos -------------------------------------------------------

variable "db_clase" {
  description = "Clase de instancia de RDS. db.t4g.micro alcanza para el piloto."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_almacenamiento_gb" {
  description = "Almacenamiento inicial de la base de datos, en GB."
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Alta disponibilidad (duplica el costo de la base). false para el piloto."
  type        = bool
  default     = false
}

# --- API -----------------------------------------------------------------

variable "api_imagen" {
  description = "Imagen de contenedor de la API en el repositorio ECR del piloto (repositorio:etiqueta), ARM64 y con Lambda Web Adapter. Vacío = no se crean las funciones, hasta que exista la aplicación."
  type        = string
  default     = ""
}

variable "api_memoria" {
  description = "Memoria de la función de la API, en MB. Lambda asigna CPU en proporción a la memoria."
  type        = number
  default     = 1024
}

variable "api_tiempo_max" {
  description = "Tiempo máximo de una solicitud a la API, en segundos. CloudFront espera hasta 30."
  type        = number
  default     = 29
  validation {
    condition     = var.api_tiempo_max >= 3 && var.api_tiempo_max <= 30
    error_message = "api_tiempo_max debe estar entre 3 y 30 segundos (límite de espera de CloudFront)."
  }
}

variable "api_concurrencia" {
  description = "Ejecuciones simultáneas reservadas para la API; protege a la base de demasiadas conexiones. -1 = sin reserva (las cuentas nuevas parten con un máximo de 10 en total y no admiten reservas hasta que AWS lo amplía)."
  type        = number
  default     = -1
}

variable "api_puerto" {
  description = "Puerto en que escucha la aplicación dentro del contenedor (Lambda Web Adapter le reenvía las solicitudes)."
  type        = number
  default     = 8080
}

variable "api_ruta_salud" {
  description = "Ruta que Lambda Web Adapter consulta al arrancar para saber que la aplicación está lista."
  type        = string
  default     = "/api/salud"
}

# --- Dominio y correo (opcionales) ---------------------------------------

variable "dominio" {
  description = "Dominio propio del sitio, p. ej. app.paritario.cl. Vacío = se usa el dominio que asigna CloudFront."
  type        = string
  default     = ""
}

variable "certificado_cloudfront_arn" {
  description = "ARN de un certificado de ACM en us-east-1 para el dominio (CloudFront solo acepta certificados de esa región). Obligatorio si se define dominio."
  type        = string
  default     = ""
}

variable "dominio_correo" {
  description = "Dominio desde el que se envían los correos con SES, p. ej. paritario.cl. Vacío = no se configura SES."
  type        = string
  default     = ""
}

# --- Horario de encendido -------------------------------------------------

variable "horario" {
  description = "siempre | dias_habiles (lunes a viernes, 07:30–19:30) | fines_de_semana (sábado 07:00 a domingo 23:00). Hora de Chile."
  type        = string
  default     = "siempre"

  validation {
    condition     = contains(["siempre", "dias_habiles", "fines_de_semana"], var.horario)
    error_message = "horario debe ser siempre, dias_habiles o fines_de_semana."
  }
}
