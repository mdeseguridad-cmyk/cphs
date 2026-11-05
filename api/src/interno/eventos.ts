// Eventos que no son HTTP, en la función de la API. Lambda Web Adapter los
// entrega como POST /interno/eventos; CloudFront solo expone /api/*, así que
// esta ruta no es accesible desde internet.
//
//   {"tipo": "sincronizar"}   programación diaria: deja un trabajo por cada
//                             integración de empresas o centros activa.
//   Evento de S3              resultado de una consulta a un cliente en
//                             importaciones/: se importa en la base.

import type { FastifyInstance } from "fastify";
import type { Contexto } from "../app.js";
import { enTransaccion, varios } from "../db.js";
import { encolarTrabajo } from "../servicios.js";

interface EventoS3 {
  Records?: { eventSource?: string; s3?: { bucket?: { name?: string }; object?: { key?: string } } }[];
}

export const claveS3 = (k: string) => decodeURIComponent(k.replace(/\+/g, " "));

export function rutasEventos(app: FastifyInstance, ctx: Contexto): void {
  app.post("/interno/eventos", async (req) => {
    const cuerpo = (req.body ?? {}) as { tipo?: string } & EventoS3;

    if (cuerpo.tipo === "sincronizar") {
      const integraciones = await enTransaccion(ctx.pool, null, (c) =>
        varios<{ id: number; tipo: string; protocolo: string; secreto_ref: string; configuracion: unknown }>(
          c,
          "SELECT * FROM integraciones_a_sincronizar()",
        ),
      );
      for (const i of integraciones) {
        await encolarTrabajo(ctx.cfg, ctx.servicios, "sincronizar", {
          integracion_id: i.id,
          integracion_tipo: i.tipo,
          protocolo: i.protocolo,
          secreto_ref: i.secreto_ref,
          configuracion: i.configuracion,
        });
      }
      req.log.info({ integraciones: integraciones.length }, "sincronización encolada");
      return { encoladas: integraciones.length };
    }

    const resultados: { clave: string; sincronizacion: number }[] = [];
    for (const r of cuerpo.Records ?? []) {
      const clave = claveS3(r.s3?.object?.key ?? "");
      if (r.eventSource !== "aws:s3" || !clave.startsWith(ctx.cfg.importacionesPrefijo)) continue;
      const contenido = JSON.parse(await ctx.servicios.almacen.leer(ctx.cfg.operacionesBucket, clave)) as {
        integracion_id: number;
        tipo: "empresas" | "centros";
        datos: unknown;
      };
      const funcion = contenido.tipo === "empresas" ? "importar_empresas" : "importar_centros";
      const sinc = await enTransaccion(ctx.pool, null, async (c) => {
        const filas = await varios<{ id: number }>(c, `SELECT ${funcion}($1, $2::jsonb, $3) AS id`, [
          contenido.integracion_id,
          JSON.stringify(contenido.datos ?? null),
          clave,
        ]);
        return filas[0]!.id;
      });
      await ctx.servicios.almacen.borrar(ctx.cfg.operacionesBucket, clave);
      req.log.info({ integracion: contenido.integracion_id, sincronizacion: sinc }, "importación registrada");
      resultados.push({ clave, sincronizacion: sinc });
    }
    return { importadas: resultados };
  });
}
