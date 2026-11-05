// Función de trabajos (MODO=trabajos): fuera de la VPC, con internet y sin
// acceso a la base. S3 la invoca cuando la API deja un trabajo en trabajos/;
// Lambda Web Adapter entrega el evento como POST /interno/trabajos.
//
//   crear_usuario        Cognito crea la cuenta y envía la invitación
//   reenviar_invitacion  Cognito reenvía la clave temporal
//   bloquear             deshabilita la cuenta y cierra sus sesiones
//   desbloquear          la habilita
//   correo               envía un correo con SES
//   sincronizar          consulta el servicio de empresas o centros de un
//                        cliente y deja el resultado en importaciones/
//
// Si un trabajo falla, la respuesta es un error: Lambda reintenta la
// invocación (S3 la hace asíncrona) y el archivo vence a los 7 días.

import type { FastifyInstance } from "fastify";
import type { Contexto } from "../app.js";
import { claveS3 } from "./eventos.js";

interface Trabajo {
  tipo: string;
  [k: string]: unknown;
}

interface SecretoServicio {
  url: string;
  token?: string;
  /** Encabezado para el token; por defecto Authorization: Bearer. */
  encabezado?: string;
}

const MAX_REGISTROS = 50_000;

/** Aplica el mapeo de campos del cliente a los de Paritario: {"contrato": "nro_adherente", …}. */
export function mapear(datos: unknown[], mapeo: Record<string, string> | undefined): unknown[] {
  if (!mapeo || Object.keys(mapeo).length === 0) return datos;
  return datos.map((fila) => {
    const f = fila as Record<string, unknown>;
    const r: Record<string, unknown> = { ...f };
    for (const [nuestro, suyo] of Object.entries(mapeo)) r[nuestro] = f[suyo];
    return r;
  });
}

async function sincronizar(ctx: Contexto, t: Trabajo): Promise<string> {
  const { servicios: s, cfg } = ctx;
  if (!/api|rest|https/i.test(String(t.protocolo))) throw new Error(`Protocolo no soportado todavía: ${String(t.protocolo)}`);
  const secreto = JSON.parse(await s.secretos.leer(String(t.secreto_ref))) as SecretoServicio;
  const headers: Record<string, string> = { accept: "application/json" };
  if (secreto.token) {
    if (secreto.encabezado) headers[secreto.encabezado] = secreto.token;
    else headers.authorization = `Bearer ${secreto.token}`;
  }
  const r = await s.http(secreto.url, { headers, signal: AbortSignal.timeout(60_000) });
  if (!r.ok) throw new Error(`El servicio del cliente respondió ${r.status}`);
  const cuerpo = (await r.json()) as unknown;
  const lista = Array.isArray(cuerpo) ? cuerpo : ((cuerpo as { datos?: unknown[]; items?: unknown[] }).datos ?? (cuerpo as { items?: unknown[] }).items);
  if (!Array.isArray(lista)) throw new Error("El servicio del cliente no entregó una lista");
  if (lista.length > MAX_REGISTROS) throw new Error(`El servicio entregó más de ${MAX_REGISTROS} registros`);
  const configuracion = (t.configuracion ?? {}) as { mapeo?: Record<string, string> };
  const clave = `${cfg.importacionesPrefijo}${String(t.integracion_id)}/${new Date().toISOString().replace(/[:.]/g, "-")}.json`;
  await s.almacen.poner(
    cfg.operacionesBucket,
    clave,
    JSON.stringify({ integracion_id: t.integracion_id, tipo: t.integracion_tipo, datos: mapear(lista, configuracion.mapeo) }),
  );
  return clave;
}

export async function ejecutarTrabajo(ctx: Contexto, t: Trabajo): Promise<unknown> {
  const { servicios: s } = ctx;
  switch (t.tipo) {
    case "crear_usuario":
      return s.identidad.crear({ rut: String(t.rut), correo: String(t.correo) });
    case "reenviar_invitacion":
      return s.identidad.reenviarInvitacion(String(t.rut));
    case "bloquear":
      return s.identidad.deshabilitar(String(t.rut));
    case "desbloquear":
      return s.identidad.habilitar(String(t.rut));
    case "correo":
      return s.correo.enviar({ para: String(t.para), asunto: String(t.asunto), texto: String(t.texto) });
    case "sincronizar":
      return sincronizar(ctx, t);
    default:
      throw new Error(`Tipo de trabajo desconocido: ${t.tipo}`);
  }
}

export function rutasTrabajos(app: FastifyInstance, ctx: Contexto): void {
  app.post("/interno/trabajos", async (req) => {
    const cuerpo = (req.body ?? {}) as { Records?: { eventSource?: string; s3?: { object?: { key?: string } } }[] };
    let hechos = 0;
    for (const r of cuerpo.Records ?? []) {
      const clave = claveS3(r.s3?.object?.key ?? "");
      if (r.eventSource !== "aws:s3" || !clave.startsWith(ctx.cfg.trabajosPrefijo)) continue;
      const t = JSON.parse(await ctx.servicios.almacen.leer(ctx.cfg.operacionesBucket, clave)) as Trabajo;
      await ejecutarTrabajo(ctx, t);
      await ctx.servicios.almacen.borrar(ctx.cfg.operacionesBucket, clave);
      req.log.info({ tipo: t.tipo }, "trabajo ejecutado");
      hechos++;
    }
    return { ejecutados: hechos };
  });
}
