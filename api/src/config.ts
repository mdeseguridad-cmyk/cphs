// Configuración desde variables de entorno (las define infra/api.tf).

export interface Config {
  modo: "api" | "trabajos";
  puerto: number;
  region: string;
  db: {
    host: string;
    puerto: number;
    nombre: string;
    usuario: string;
    /** "iam": token de IAM generado por el SDK; "clave": DB_PASSWORD (solo desarrollo y pruebas). */
    auth: "iam" | "clave";
    clave?: string;
    sslmode: "disable" | "require" | "verify-full";
    /** Certificados de RDS para verify-full. */
    caPath: string;
    maxConexiones: number;
    /** Espera máxima para abrir una conexión. Con IAM, RDS valida el token y puede tardar varios segundos. */
    tiempoConexionMs: number;
  };
  documentosBucket: string;
  operacionesBucket: string;
  trabajosPrefijo: string;
  importacionesPrefijo: string;
  cognito: {
    userPoolId: string;
    clientId: string;
    emisor: string;
    /** JWKS incluido en la imagen: la función de la API no tiene internet. */
    jwksPath: string;
  };
  correoRemitente: string;
}

function req(env: NodeJS.ProcessEnv, nombre: string): string {
  const v = env[nombre];
  if (!v) throw new Error(`Falta la variable de entorno ${nombre}`);
  return v;
}

export function leerConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const modo = env.MODO === "trabajos" ? "trabajos" : "api";
  const auth = env.DB_AUTH === "clave" ? "clave" : "iam";
  const sslmode = (env.DB_SSLMODE ?? "verify-full") as Config["db"]["sslmode"];
  if (!["disable", "require", "verify-full"].includes(sslmode)) {
    throw new Error(`DB_SSLMODE inválido: ${sslmode}`);
  }
  return {
    modo,
    puerto: Number(env.AWS_LWA_PORT ?? env.PUERTO ?? 8080),
    region: env.AWS_REGION ?? "sa-east-1",
    db: {
      // La función de trabajos no llega a la base.
      host: modo === "api" ? req(env, "DB_HOST") : (env.DB_HOST ?? ""),
      puerto: Number(env.DB_PORT ?? 5432),
      nombre: env.DB_NAME ?? "paritario",
      usuario: env.DB_USER ?? "paritario_app",
      auth,
      clave: env.DB_PASSWORD,
      sslmode,
      caPath: env.DB_CA_PATH ?? "/opt/paritario/rds-ca.pem",
      maxConexiones: Number(env.DB_MAX_CONEXIONES ?? 2),
      tiempoConexionMs: Number(env.DB_TIEMPO_CONEXION_MS ?? 25_000),
    },
    documentosBucket: env.DOCUMENTOS_BUCKET ?? "",
    operacionesBucket: env.OPERACIONES_BUCKET ?? "",
    trabajosPrefijo: env.TRABAJOS_PREFIJO ?? "trabajos/",
    importacionesPrefijo: env.IMPORTACIONES_PREFIJO ?? "importaciones/",
    cognito: {
      userPoolId: env.COGNITO_USER_POOL_ID ?? "",
      clientId: env.COGNITO_CLIENT_ID ?? "",
      emisor: env.COGNITO_EMISOR ?? "",
      jwksPath: env.COGNITO_JWKS_PATH ?? "/opt/paritario/jwks.json",
    },
    correoRemitente: env.CORREO_REMITENTE ?? "",
  };
}
