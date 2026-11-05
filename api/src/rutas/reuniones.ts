// Reuniones del comité: cronograma mensual (DS 44: al menos una al mes),
// asistencia y acta.

import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Contexto } from "../app.js";
import { datos, fecha, id } from "../validacion.js";
import { actualizar, bitacora, insertar, uno, varios } from "../db.js";
import { invalido, noEncontrado } from "../errores.js";
import { comiteEditable, comiteVisible } from "./comun.js";

const anio = z.number().int().min(2000).max(2100);

const reunionCambio = z.object({
  estado: z.enum(["planificada", "realizada", "no_realizada"]).optional(),
  fecha_programada: fecha.nullable().optional(),
  fecha_realizada: fecha.nullable().optional(),
  observacion: z.string().trim().max(2000).nullable().optional(),
  acta_documento_id: z.number().int().positive().nullable().optional(),
});

export function rutasReuniones(app: FastifyInstance, ctx: Contexto): void {
  app.get("/api/comites/:id/reuniones", (req) =>
    ctx.tx(req, async (c) => {
      const cm = await comiteVisible(c, id(req));
      const q = req.query as { anio?: string };
      return varios(
        c,
        `SELECT r.id, r.anio, r.mes, r.numero, r.estado, r.fecha_programada, r.fecha_realizada, r.observacion,
                r.acta_documento_id, d.nombre AS acta,
                (SELECT count(*) FILTER (WHERE ra.presente) FROM reunion_asistencia ra WHERE ra.reunion_id = r.id) AS presentes
           FROM reunion r LEFT JOIN documento d ON d.id = r.acta_documento_id
          WHERE r.comite_id = $1 AND ($2::int IS NULL OR r.anio = $2)
          ORDER BY r.anio DESC, r.mes, r.numero`,
        [cm.id, q.anio ? Number(q.anio) : null],
      );
    }),
  );

  app.post("/api/comites/:id/reuniones", async (req, rep) => {
    const d = datos(z.object({ anio, mes: z.number().int().min(1).max(12), fecha_programada: fecha.optional() }), req.body);
    const nuevo = await ctx.tx(req, async (c, s) => {
      const cm = await comiteEditable(c, s, id(req));
      const n = await uno<{ n: number }>(c, "SELECT coalesce(max(numero), 0) + 1 AS n FROM reunion WHERE comite_id = $1 AND anio = $2", [cm.id, d.anio]);
      return insertar(c, "reunion", { comite_id: cm.id, anio: d.anio, mes: d.mes, numero: n!.n, fecha_programada: d.fecha_programada });
    });
    return rep.status(201).send({ id: nuevo });
  });

  // Crea las reuniones ordinarias del año: una por mes, en los meses que no
  // tienen, desde el mes de constitución del comité (antes no se exigen).
  app.post("/api/comites/:id/cronograma", async (req, rep) => {
    const d = datos(z.object({ anio }), req.body);
    const r = await ctx.tx(req, async (c, s) => {
      const cm = await comiteEditable(c, s, id(req));
      const meses = await varios<{ mes: number }>(c, "SELECT DISTINCT mes FROM reunion WHERE comite_id = $1 AND anio = $2", [cm.id, d.anio]);
      const ocupados = new Set(meses.map((m) => m.mes));
      const constitucion = await uno<{ fecha: string | null }>(c, "SELECT fecha_constitucion AS fecha FROM comite WHERE id = $1", [cm.id]);
      const [anioConst, mesConst] = (constitucion?.fecha ?? "").split("-").map(Number);
      const desde = !anioConst || anioConst < d.anio ? 1 : anioConst > d.anio ? 13 : mesConst!;
      const n = await uno<{ n: number }>(c, "SELECT coalesce(max(numero), 0) AS n FROM reunion WHERE comite_id = $1 AND anio = $2", [cm.id, d.anio]);
      let numero = n!.n;
      let creadas = 0;
      for (let mes = desde; mes <= 12; mes++) {
        if (ocupados.has(mes)) continue;
        await insertar(c, "reunion", { comite_id: cm.id, anio: d.anio, mes, numero: ++numero });
        creadas++;
      }
      return { creadas };
    });
    return rep.status(201).send(r);
  });

  app.patch("/api/reuniones/:id", (req) =>
    ctx.tx(req, async (c, s) => {
      const reunionId = id(req);
      const r = await uno<{ comite_id: number }>(c, "SELECT comite_id FROM reunion WHERE id = $1", [reunionId]);
      if (!r) throw noEncontrado("Reunión no encontrada");
      await comiteEditable(c, s, r.comite_id);
      const d = datos(reunionCambio, req.body);
      if (d.estado && d.estado !== "realizada") d.fecha_realizada = null;
      if (d.estado === "realizada" && !d.fecha_realizada) throw invalido("Una reunión realizada necesita su fecha");
      if (d.acta_documento_id) {
        const doc = await uno(
          c,
          "SELECT 1 FROM documento WHERE id = $1 AND comite_id = $2 AND estado = 'disponible' AND tipo IN ('reunion', 'constitucion')",
          [d.acta_documento_id, r.comite_id],
        );
        if (!doc) throw invalido("El acta debe ser un documento disponible de tipo reunión o constitución, de este comité");
      }
      await actualizar(c, "reunion", reunionId, d);
      return { id: reunionId };
    }),
  );

  app.get("/api/reuniones/:id/asistencia", (req) =>
    ctx.tx(req, async (c, s) => {
      const reunionId = id(req);
      const r = await uno<{ comite_id: number }>(c, "SELECT comite_id FROM reunion WHERE id = $1", [reunionId]);
      if (!r) throw noEncontrado("Reunión no encontrada");
      const filas = await varios(
        c,
        `SELECT ci.id AS integrante_id, p.nombres, p.apellidos, ci.tipo, ci.representacion, ci.cargo,
                ra.presente, ra.justificacion
           FROM comite_integrante ci
           JOIN persona p ON p.id = ci.persona_id
           LEFT JOIN reunion_asistencia ra ON ra.integrante_id = ci.id AND ra.reunion_id = $1
          WHERE ci.comite_id = $2 AND (ci.vigente OR ra.id IS NOT NULL)
          ORDER BY ci.tipo, p.apellidos`,
        [reunionId, r.comite_id],
      );
      if (filas.length) await bitacora(c, s.usuarioId, "ver", "reunion_asistencia", reunionId);
      return filas;
    }),
  );

  app.put("/api/reuniones/:id/asistencia", (req) =>
    ctx.tx(req, async (c, s) => {
      const reunionId = id(req);
      const r = await uno<{ comite_id: number }>(c, "SELECT comite_id FROM reunion WHERE id = $1", [reunionId]);
      if (!r) throw noEncontrado("Reunión no encontrada");
      await comiteEditable(c, s, r.comite_id);
      const d = datos(
        z.object({
          asistencia: z
            .array(z.object({ integrante_id: z.number().int().positive(), presente: z.boolean(), justificacion: z.string().trim().max(200).optional() }))
            .max(60),
        }),
        req.body,
      );
      const ids = d.asistencia.map((a) => a.integrante_id);
      const validos = await varios<{ id: number }>(c, "SELECT id FROM comite_integrante WHERE comite_id = $1 AND id = ANY($2::bigint[])", [r.comite_id, ids]);
      if (validos.length !== new Set(ids).size) throw invalido("Hay asistentes que no son integrantes del comité");
      for (const a of d.asistencia) {
        await c.query(
          `INSERT INTO reunion_asistencia (reunion_id, integrante_id, presente, justificacion) VALUES ($1, $2, $3, $4)
           ON CONFLICT (reunion_id, integrante_id) DO UPDATE SET presente = EXCLUDED.presente, justificacion = EXCLUDED.justificacion`,
          [reunionId, a.integrante_id, a.presente, a.presente ? null : (a.justificacion ?? null)],
        );
      }
      await bitacora(c, s.usuarioId, "editar", "reunion_asistencia", reunionId);
      return { id: reunionId, registrados: d.asistencia.length };
    }),
  );
}
