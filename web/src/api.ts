// Cliente de la API. El token va en X-Token-Usuario (CloudFront usa
// Authorization para firmar la llamada a la función) y cada cuerpo lleva su
// SHA-256 en x-amz-content-sha256, que CloudFront exige al firmar hacia Lambda.

import { autenticador } from "./auth/autenticador";

export class ErrorApi extends Error {
  constructor(
    public status: number,
    public codigo: string,
    mensaje: string,
    public detalle?: { campo: string; mensaje: string }[],
  ) {
    super(mensaje);
  }
}

export async function sha256Hex(datos: string | ArrayBuffer): Promise<string> {
  const bytes = typeof datos === "string" ? new TextEncoder().encode(datos) : datos;
  const h = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

let alExpirar: (() => void) | null = null;
/** La aplicación registra qué hacer cuando la sesión vence (volver al ingreso). */
export function siLaSesionExpira(fn: () => void): void {
  alExpirar = fn;
}

export async function api<T = unknown>(metodo: "GET" | "POST" | "PUT" | "PATCH" | "DELETE", ruta: string, cuerpo?: unknown): Promise<T> {
  const token = await autenticador().token();
  if (!token) {
    alExpirar?.();
    throw new ErrorApi(401, "no_autenticado", "Su sesión terminó");
  }
  const texto = cuerpo === undefined ? "" : JSON.stringify(cuerpo);
  const headers: Record<string, string> = { "x-token-usuario": token, accept: "application/json" };
  if (metodo !== "GET") {
    headers["x-amz-content-sha256"] = await sha256Hex(texto);
    if (cuerpo !== undefined) headers["content-type"] = "application/json";
  }
  let r: Response;
  try {
    r = await fetch(ruta, { method: metodo, headers, body: cuerpo === undefined ? undefined : texto });
  } catch {
    throw new ErrorApi(0, "red", "No hay conexión con el servidor");
  }
  const datos = r.status === 204 ? null : await r.json().catch(() => null);
  if (!r.ok) {
    const d = (datos ?? {}) as { error?: string; mensaje?: string; detalle?: ErrorApi["detalle"] };
    if (r.status === 401) alExpirar?.();
    if (r.status === 502 || r.status === 503 || r.status === 504) {
      throw new ErrorApi(r.status, "no_disponible", "El sistema no está disponible en este momento. Si el piloto tiene horario, intente dentro del horario de uso.");
    }
    throw new ErrorApi(r.status, d.error ?? "error", d.mensaje ?? `Error ${r.status}`, d.detalle);
  }
  return datos as T;
}

export interface Subida {
  id: number;
  subida: { url: string; encabezados: Record<string, string> };
}

/** Sube un archivo: registro en la API, PUT directo a S3 con su huella y confirmación. */
export async function subirDocumento(
  comiteId: number,
  archivo: File,
  meta: { tipo: string; nombre: string; fecha_documento?: string },
): Promise<number> {
  const contenido = await archivo.arrayBuffer();
  const sha256 = await sha256Hex(contenido);
  const r = await api<Subida>("POST", `/api/comites/${comiteId}/documentos`, {
    ...meta,
    mime: archivo.type || "application/octet-stream",
    tamano_bytes: archivo.size,
    sha256,
  });
  const put = await fetch(r.subida.url, { method: "PUT", headers: r.subida.encabezados, body: contenido });
  if (!put.ok) throw new ErrorApi(put.status, "subida", "No se pudo subir el archivo");
  await api("POST", `/api/documentos/${r.id}/confirmar`);
  return r.id;
}
