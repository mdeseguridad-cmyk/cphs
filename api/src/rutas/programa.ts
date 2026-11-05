// Programa de trabajo: plantillas por rubro y actividades (flujo Kanban:
// planificado → en_ejecucion → cerrado).

import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Contexto } from "../app.js";
import { datos, fecha, id } from "../validacion.js";
import { actualizar, insertar, uno, varios, type Cliente } from "../db.js";
import { conflicto, invalido, noEncontrado } from "../errores.js";
import { comiteEditable, comiteVisible } from "./comun.js";

const FRECUENCIAS = ["quincenal", "mensual", "trimestral", "semestral", "anual", "unica", "segun_evento"] as const;

const actividadNueva = z.object({
  titulo: z.string().trim().min(1).max(200),
  descripcion: z.string().trim().max(4000).optional(),
  clasificacion: z.enum(["obligatoria_ley", "recomendada"]).optional(),
  frecuencia: z.enum(FRECUENCIAS).optional(),
  fecha_planificada: fecha.optional(),
  comision_id: z.number().int().positive().optional(),
  responsable_integrante_id: z.number().int().positive().optional(),
  actividad_padre_id: z.number().int().positive().optional(),
});

const actividadCambio = actividadNueva
  .partial()
  .extend({
    estado: z.enum(["planificado", "en_ejecucion", "cerrado"]).optional(),
    fecha_cierre: fecha.optional(),
    evidencia_documento_id: z.number().int().positive().nullable().optional(),
  });

/** Comisión, responsable, actividad padre y evidencia deben ser del mismo comité. */
async function validarReferencias(
  c: Cliente,
  comiteId: number,
  d: { comision_id?: number; responsable_integrante_id?: number; actividad_padre_id?: number; evidencia_documento_id?: number | null },
): Promise<void> {
  const checks: [number | null | undefined, string, string][] = [
    [d.comision_id, "SELECT 1 FROM comision WHERE id = $1 AND comite_id = $2", "La comisión no es de este comité"],
    [d.responsable_integrante_id, "SELECT 1 FROM comite_integrante WHERE id = $1 AND comite_id = $2 AND vigente", "El responsable no es integrante vigente del comité"],
    [d.actividad_padre_id, "SELECT 1 FROM actividad WHERE id = $1 AND comite_id = $2", "La actividad padre no es de este comité"],
    [d.evidencia_documento_id, "SELECT 1 FROM documento WHERE id = $1 AND comite_id = $2 AND estado = 'disponible'", "La evidencia no es un documento disponible del comité"],
  ];
  for (const [v, sql, msg] of checks) {
    if (v && !(await uno(c, sql, [v, comiteId]))) throw invalido(msg);
  }
}

export function rutasPrograma(app: FastifyInstance, ctx: Contexto): void {
  // Plantillas visibles: las generales y las del organismo de la empresa.
  app.get("/api/plantillas", (req) =>
    ctx.tx(req, (c) => {
      const q = req.query as { seccion?: string };
      return varios(
        c,
        `SELECT pp.id, pp.nombre, pp.seccion, pp.organismo_id, pp.ds_referencia, pp.descripcion,
                (SELECT count(*) FROM actividad_tipo at WHERE at.plantilla_id = pp.id) AS actividades
           FROM programa_plantilla pp
          WHERE pp.vigente AND ($1::text IS NULL OR pp.seccion = $1)
          ORDER BY pp.organismo_id NULLS LAST, pp.nombre`,
        [q.seccion ?? null],
      );
    }),
  );

  app.get("/api/plantillas/:id/actividades", (req) =>
    ctx.tx(req, async (c) => {
      const pp = await uno(c, "SELECT id FROM programa_plantilla WHERE id = $1", [id(req)]);
      if (!pp) throw noEncontrado("Plantilla no encontrada");
      return varios(
        c,
        "SELECT id, titulo, descripcion, clasificacion, frecuencia, comision_tipo FROM actividad_tipo WHERE plantilla_id = $1 ORDER BY id",
        [pp.id],
      );
    }),
  );

  // Instancia el programa del comité desde una plantilla. Las actividades con
  // comisión quedan asignadas a la comisión de ese tipo, si el comité la tiene.
  app.post("/api/comites/:id/programa", async (req, rep) => {
    const d = datos(z.object({ plantilla_id: z.number().int().positive(), anio: z.number().int().min(2000).max(2100).optional() }), req.body);
    const r = await ctx.tx(req, async (c, s) => {
      const cm = await comiteEditable(c, s, id(req));
      const tipos = await varios<{ id: number; titulo: string; descripcion: string | null; clasificacion: string; frecuencia: string; comision_tipo: string | null }>(
        c,
        `SELECT at.id, at.titulo, at.descripcion, at.clasificacion, at.frecuencia, at.comision_tipo
           FROM actividad_tipo at JOIN programa_plantilla pp ON pp.id = at.plantilla_id
          WHERE pp.id = $1 AND pp.vigente ORDER BY at.id`,
        [d.plantilla_id],
      );
      if (!tipos.length) throw noEncontrado("Plantilla no encontrada o sin actividades");
      const ya = await uno(c, "SELECT 1 FROM actividad WHERE comite_id = $1 AND actividad_tipo_id = ANY($2::bigint[])", [cm.id, tipos.map((t) => t.id)]);
      if (ya) throw conflicto("El comité ya tiene el programa de esta plantilla");
      const comisiones = await varios<{ id: number; tipo: string }>(c, "SELECT id, tipo FROM comision WHERE comite_id = $1 ORDER BY id", [cm.id]);
      const anio = d.anio ?? new Date().getFullYear();
      let creadas = 0;
      for (const t of tipos) {
        await insertar(c, "actividad", {
          comite_id: cm.id,
          actividad_tipo_id: t.id,
          titulo: t.titulo,
          descripcion: t.descripcion ?? undefined,
          clasificacion: t.clasificacion,
          frecuencia: t.frecuencia,
          comision_id: comisiones.find((x) => x.tipo === t.comision_tipo)?.id,
          fecha_planificada: `${anio}-12-31`,
        });
        creadas++;
      }
      return { creadas };
    });
    return rep.status(201).send(r);
  });

  app.get("/api/comites/:id/actividades", (req) =>
    ctx.tx(req, async (c) => {
      const cm = await comiteVisible(c, id(req));
      const q = req.query as { estado?: string };
      return varios(
        c,
        `SELECT a.id, a.titulo, a.descripcion, a.clasificacion, a.frecuencia, a.estado, a.fecha_planificada,
                a.fecha_cierre, a.comision_id, a.responsable_integrante_id, a.actividad_padre_id,
                a.evidencia_documento_id, a.actividad_tipo_id,
                (a.estado <> 'cerrado' AND a.fecha_planificada < current_date) AS atrasada
           FROM actividad a
          WHERE a.comite_id = $1 AND ($2::text IS NULL OR a.estado::text = $2)
          ORDER BY a.estado, a.fecha_planificada NULLS LAST, a.id`,
        [cm.id, q.estado ?? null],
      );
    }),
  );

  app.post("/api/comites/:id/actividades", async (req, rep) => {
    const d = datos(actividadNueva, req.body);
    const nuevo = await ctx.tx(req, async (c, s) => {
      const cm = await comiteEditable(c, s, id(req));
      await validarReferencias(c, cm.id, d);
      return insertar(c, "actividad", { comite_id: cm.id, ...d });
    });
    return rep.status(201).send({ id: nuevo });
  });

  app.patch("/api/actividades/:id", (req) =>
    ctx.tx(req, async (c, s) => {
      const actividadId = id(req);
      const a = await uno<{ comite_id: number; estado: string }>(c, "SELECT comite_id, estado FROM actividad WHERE id = $1", [actividadId]);
      if (!a) throw noEncontrado("Actividad no encontrada");
      await comiteEditable(c, s, a.comite_id);
      const d = datos(actividadCambio, req.body);
      await validarReferencias(c, a.comite_id, d);
      const cambios: Record<string, unknown> = { ...d };
      // Cerrar fija la fecha de cierre (hoy, si no se indica); reabrir la quita.
      if (d.estado === "cerrado") cambios.fecha_cierre = d.fecha_cierre ?? new Date().toISOString().slice(0, 10);
      else if (d.estado) cambios.fecha_cierre = null;
      else if (d.fecha_cierre && a.estado !== "cerrado") throw invalido("Solo una actividad cerrada tiene fecha de cierre");
      await actualizar(c, "actividad", actividadId, cambios);
      return { id: actividadId };
    }),
  );
}
