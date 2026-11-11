// Errores de la API y traducción de los errores de PostgreSQL a respuestas HTTP.

export class ErrorApi extends Error {
  constructor(
    public readonly status: number,
    public readonly codigo: string,
    mensaje: string,
    public readonly detalle?: unknown,
  ) {
    super(mensaje);
  }
}

export const noAutenticado = (m = "Se requiere iniciar sesión") => new ErrorApi(401, "no_autenticado", m);
export const prohibido = (m = "No tiene permiso para esta operación") => new ErrorApi(403, "prohibido", m);
export const noEncontrado = (m = "No encontrado") => new ErrorApi(404, "no_encontrado", m);
export const conflicto = (m: string) => new ErrorApi(409, "conflicto", m);
export const invalido = (m: string, detalle?: unknown) => new ErrorApi(422, "invalido", m, detalle);

interface ErrorPg {
  code?: string;
  message: string;
  constraint?: string;
}

/** La base no respondió a tiempo al abrir la conexión (apagada, o lenta en validar el acceso). */
function sinConexion(e: unknown): boolean {
  const m = (e as Error)?.message ?? "";
  return /connection timeout|timeout exceeded when trying to connect|ECONNREFUSED|ETIMEDOUT/.test(m);
}

/** Convierte un error de PostgreSQL en un ErrorApi. Los mensajes no incluyen datos de las filas. */
export function desdePostgres(e: unknown): ErrorApi | null {
  if (sinConexion(e)) {
    return new ErrorApi(503, "base_no_disponible", "La base de datos no respondió a tiempo. Intente de nuevo en unos segundos.");
  }
  const err = e as ErrorPg;
  if (!err || typeof err.code !== "string") return null;
  const reglas: Record<string, string> = {
    comite_presidente_uq: "El comité ya tiene un presidente vigente",
    comite_secretario_uq: "El comité ya tiene un secretario vigente",
    comite_aforado_uq: "El comité ya tiene un integrante aforado vigente",
    comite_integrante_persona_vigente_uq: "La persona ya integra este comité",
  };
  switch (err.code) {
    case "23505":
      if (err.constraint && reglas[err.constraint]) return invalido(reglas[err.constraint]!);
      return conflicto("Ya existe un registro con esos datos");
    case "23503":
      return invalido("Hace referencia a un registro que no existe o no es visible");
    case "23502":
      return invalido("Falta un dato obligatorio");
    case "23514":
    case "23P01":
      return invalido(`No cumple una regla de negocio (${err.constraint ?? "restricción"})`);
    case "22P02":
    case "22007":
    case "22008":
      return invalido("Formato de dato inválido");
    case "P0001":
      return invalido(err.message);
    case "42501":
      return prohibido("Fuera de su ámbito");
    case "28000":
      return new ErrorApi(403, "acceso_denegado", err.message);
    default:
      return null;
  }
}
