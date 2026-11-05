// Comités, integrantes y comisiones (DS 44/2024).

import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Contexto } from "../app.js";
import { datos, fecha, id, rut } from "../validacion.js";
import { actualizar, bitacora, insertar, uno, varios } from "../db.js";
import { invalido, noEncontrado } from "../errores.js";
import { esAdminEmpresa, exigir } from "../permisos.js";
import { comiteEditable, comiteVisible } from "./comun.js";

const comiteNuevo = z.object({
  empresa_id: z.number().int().positive(),
  sucursal_id: z.number().int().positive().optional(),
  nombre: z.string().trim().min(1).max(180),
  fecha_constitucion: fecha.optional(),
  periodo_inicio: fecha.optional(),
  periodo_fin: fecha.optional(),
  n_titulares: z.number().int().min(1).max(10).optional(),
  n_suplentes: z.number().int().min(0).max(10).optional(),
});

const comiteCambio = comiteNuevo.omit({ empresa_id: true }).partial();

const integranteNuevo = z.object({
  rut,
  nombres: z.string().trim().min(1).max(120),
  apellidos: z.string().trim().min(1).max(120),
  email: z.string().email().max(160).optional(),
  tipo: z.enum(["titular", "suplente"]),
  representacion: z.enum(["empresa", "trabajadores"]),
  cargo: z.enum(["presidente", "secretario", "integrante"]).optional(),
  es_aforado: z.boolean().optional(),
  fecha_fuero: fecha.optional(),
  fecha_inicio: fecha.optional(),
});

const integranteCambio = z.object({
  cargo: z.enum(["presidente", "secretario", "integrante"]).optional(),
  es_aforado: z.boolean().optional(),
  fecha_fuero: fecha.nullable().optional(),
});

const COMISIONES = ["investigacion_accidentes", "capacitacion_difusion", "inspeccion_observacion", "personalizada"] as const;

export function rutasComites(app: FastifyInstance, ctx: Contexto): void {
  // --- Comités -----------------------------------------------------------------

  app.get("/api/comites", (req) =>
    ctx.tx(req, (c) => {
      const q = req.query as { empresa_id?: string; estado?: string };
      return varios(
        c,
        `SELECT cm.id, cm.nombre, cm.empresa_id, e.razon_social AS empresa, cm.sucursal_id, s.nombre AS centro,
                co.nombre AS comuna, cm.estado, cm.fecha_constitucion, cm.periodo_inicio, cm.periodo_fin,
                p.es_paritario, v.porcentaje AS cumplimiento
           FROM comite cm
           JOIN empresa e ON e.id = cm.empresa_id
           LEFT JOIN sucursal s ON s.id = cm.sucursal_id
           LEFT JOIN comuna co ON co.id = s.comuna_id
           LEFT JOIN v_paridad_comite p ON p.comite_id = cm.id
           LEFT JOIN v_cumplimiento_reuniones v ON v.comite_id = cm.id AND v.anio = extract(year FROM current_date)
          WHERE ($1::bigint IS NULL OR cm.empresa_id = $1)
            AND ($2::text IS NULL OR cm.estado::text = $2)
          ORDER BY cm.estado, cm.nombre`,
        [q.empresa_id ? Number(q.empresa_id) : null, q.estado ?? null],
      );
    }),
  );

  app.post("/api/comites", async (req, rep) => {
    const d = datos(comiteNuevo, req.body);
    const nuevo = await ctx.tx(req, async (c, s) => {
      exigir(esAdminEmpresa(s, d.empresa_id), "Solo el administrador de la empresa crea comités");
      if (d.sucursal_id) {
        const suc = await uno(c, "SELECT 1 FROM sucursal WHERE id = $1 AND empresa_id = $2", [d.sucursal_id, d.empresa_id]);
        if (!suc) throw invalido("El centro de trabajo no pertenece a la empresa");
      }
      return insertar(c, "comite", d);
    });
    return rep.status(201).send({ id: nuevo });
  });

  app.get("/api/comites/:id", (req) =>
    ctx.tx(req, async (c) => {
      const cm = await uno(
        c,
        `SELECT cm.*, e.razon_social AS empresa, s.nombre AS centro, co.nombre AS comuna
           FROM comite cm
           JOIN empresa e ON e.id = cm.empresa_id
           LEFT JOIN sucursal s ON s.id = cm.sucursal_id
           LEFT JOIN comuna co ON co.id = s.comuna_id
          WHERE cm.id = $1`,
        [id(req)],
      );
      if (!cm) throw noEncontrado("Comité no encontrado");
      const paridad = await uno(c, "SELECT * FROM v_paridad_comite WHERE comite_id = $1", [cm.id]);
      const cumplimiento = await varios(c, "SELECT * FROM v_cumplimiento_reuniones WHERE comite_id = $1 ORDER BY anio DESC", [cm.id]);
      return { ...cm, paridad, cumplimiento };
    }),
  );

  app.patch("/api/comites/:id", (req) =>
    ctx.tx(req, async (c, s) => {
      const cm = await comiteEditable(c, s, id(req));
      const d = datos(comiteCambio, req.body);
      await actualizar(c, "comite", cm.id, d);
      return { id: cm.id };
    }),
  );

  // Un comité nunca se borra: se da de baja con su fecha de disolución.
  app.post("/api/comites/:id/baja", (req) =>
    ctx.tx(req, async (c, s) => {
      const cm = await comiteVisible(c, id(req));
      exigir(esAdminEmpresa(s, cm.empresa_id), "Solo el administrador de la empresa da de baja un comité");
      const d = datos(z.object({ fecha_disolucion: fecha }), req.body);
      await actualizar(c, "comite", cm.id, { estado: "baja", fecha_disolucion: d.fecha_disolucion });
      return { id: cm.id, estado: "baja" };
    }),
  );

  // --- Integrantes --------------------------------------------------------------

  app.get("/api/comites/:id/integrantes", (req) =>
    ctx.tx(req, async (c, s) => {
      const cm = await comiteVisible(c, id(req));
      const filas = await varios(
        c,
        `SELECT ci.id, ci.tipo, ci.representacion, ci.cargo, ci.es_aforado, ci.fecha_fuero, ci.fecha_inicio,
                ci.fecha_termino, ci.vigente, p.id AS persona_id, p.rut, p.nombres, p.apellidos, p.email
           FROM comite_integrante ci JOIN persona p ON p.id = ci.persona_id
          WHERE ci.comite_id = $1
          ORDER BY ci.vigente DESC, ci.tipo, ci.representacion, p.apellidos`,
        [cm.id],
      );
      if (filas.length) await bitacora(c, s.usuarioId, "ver", "comite_integrante", cm.id);
      return filas;
    }),
  );

  app.post("/api/comites/:id/integrantes", async (req, rep) => {
    const d = datos(integranteNuevo, req.body);
    const nuevo = await ctx.tx(req, async (c, s) => {
      const cm = await comiteEditable(c, s, id(req));
      const persona = await uno<{ id: number }>(c, "SELECT asegurar_persona($1, $2, $3, $4) AS id", [d.rut, d.nombres, d.apellidos, d.email ?? null]);
      const vigente = await uno(
        c,
        "SELECT 1 FROM comite_integrante WHERE comite_id = $1 AND persona_id = $2 AND vigente",
        [cm.id, persona!.id],
      );
      if (vigente) throw invalido("La persona ya integra este comité");
      const integranteId = await insertar(c, "comite_integrante", {
        comite_id: cm.id,
        persona_id: persona!.id,
        tipo: d.tipo,
        representacion: d.representacion,
        cargo: d.cargo,
        es_aforado: d.es_aforado,
        fecha_fuero: d.fecha_fuero,
        fecha_inicio: d.fecha_inicio,
      });
      await bitacora(c, s.usuarioId, "crear", "comite_integrante", integranteId);
      return integranteId;
    });
    return rep.status(201).send({ id: nuevo });
  });

  app.patch("/api/integrantes/:id", (req) =>
    ctx.tx(req, async (c, s) => {
      const integranteId = id(req);
      const ci = await uno<{ comite_id: number }>(c, "SELECT comite_id FROM comite_integrante WHERE id = $1 AND vigente", [integranteId]);
      if (!ci) throw noEncontrado("Integrante no encontrado o no vigente");
      await comiteEditable(c, s, ci.comite_id);
      const d = datos(integranteCambio, req.body);
      await actualizar(c, "comite_integrante", integranteId, d);
      await bitacora(c, s.usuarioId, "editar", "comite_integrante", integranteId);
      return { id: integranteId };
    }),
  );

  // Término de la participación: se conserva el historial.
  app.post("/api/integrantes/:id/termino", (req) =>
    ctx.tx(req, async (c, s) => {
      const integranteId = id(req);
      const ci = await uno<{ comite_id: number }>(c, "SELECT comite_id FROM comite_integrante WHERE id = $1 AND vigente", [integranteId]);
      if (!ci) throw noEncontrado("Integrante no encontrado o no vigente");
      await comiteEditable(c, s, ci.comite_id);
      const d = datos(z.object({ fecha_termino: fecha }), req.body);
      await actualizar(c, "comite_integrante", integranteId, { fecha_termino: d.fecha_termino, vigente: false, es_aforado: false, fecha_fuero: null });
      await bitacora(c, s.usuarioId, "editar", "comite_integrante", integranteId);
      return { id: integranteId, vigente: false };
    }),
  );

  // --- Comisiones -----------------------------------------------------------------

  app.get("/api/comites/:id/comisiones", (req) =>
    ctx.tx(req, async (c) => {
      const cm = await comiteVisible(c, id(req));
      return varios(
        c,
        `SELECT co.id, co.tipo, co.nombre,
                coalesce(array_agg(ci.integrante_id ORDER BY ci.integrante_id) FILTER (WHERE ci.id IS NOT NULL), '{}') AS integrantes
           FROM comision co LEFT JOIN comision_integrante ci ON ci.comision_id = co.id
          WHERE co.comite_id = $1
          GROUP BY co.id ORDER BY co.id`,
        [cm.id],
      );
    }),
  );

  app.post("/api/comites/:id/comisiones", async (req, rep) => {
    const d = datos(z.object({ tipo: z.enum(COMISIONES), nombre: z.string().trim().max(160).optional() }), req.body);
    const nuevo = await ctx.tx(req, async (c, s) => {
      const cm = await comiteEditable(c, s, id(req));
      return insertar(c, "comision", { comite_id: cm.id, tipo: d.tipo, nombre: d.nombre });
    });
    return rep.status(201).send({ id: nuevo });
  });

  // Reemplaza los integrantes de una comisión (deben ser integrantes vigentes del comité).
  app.put("/api/comisiones/:id/integrantes", (req) =>
    ctx.tx(req, async (c, s) => {
      const comisionId = id(req);
      const co = await uno<{ comite_id: number }>(c, "SELECT comite_id FROM comision WHERE id = $1", [comisionId]);
      if (!co) throw noEncontrado("Comisión no encontrada");
      await comiteEditable(c, s, co.comite_id);
      const d = datos(z.object({ integrantes: z.array(z.number().int().positive()).max(50) }), req.body);
      const ids = [...new Set(d.integrantes)];
      const validos = await varios<{ id: number }>(
        c,
        "SELECT id FROM comite_integrante WHERE comite_id = $1 AND vigente AND id = ANY($2::bigint[])",
        [co.comite_id, ids],
      );
      if (validos.length !== ids.length) throw invalido("Hay integrantes que no son integrantes vigentes del comité");
      await c.query("DELETE FROM comision_integrante WHERE comision_id = $1", [comisionId]);
      for (const i of ids) await insertar(c, "comision_integrante", { comision_id: comisionId, integrante_id: i });
      return { id: comisionId, integrantes: ids };
    }),
  );
}
