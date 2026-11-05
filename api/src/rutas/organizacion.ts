// Usuario actual, empresas, centros de trabajo, indicadores y catálogos.

import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Contexto } from "../app.js";
import { datos, id } from "../validacion.js";
import { actualizar, insertar, uno, varios } from "../db.js";
import { conflicto, noEncontrado } from "../errores.js";
import { esAdminEmpresa, exigir } from "../permisos.js";

const centroNuevo = z.object({
  nombre: z.string().trim().min(1).max(160),
  alias: z.string().trim().max(120).optional(),
  direccion_calle: z.string().trim().max(160).optional(),
  direccion_numero: z.string().trim().max(20).optional(),
  comuna_id: z.number().int().positive().optional(),
  masa_trabajadores: z.number().int().min(0).optional(),
});

const centroCambio = centroNuevo.partial().extend({ estado: z.enum(["vigente", "no_vigente"]).optional() });

export function rutasOrganizacion(app: FastifyInstance, ctx: Contexto): void {
  app.get("/api/yo", (req) =>
    ctx.tx(req, async (c, s) => {
      const u = await uno(
        c,
        `SELECT u.id, u.rut, u.estado, u.mfa_habilitado, p.nombres, p.apellidos, p.email
           FROM usuario u LEFT JOIN persona p ON p.id = u.persona_id WHERE u.id = $1`,
        [s.usuarioId],
      );
      const roles = await varios(
        c,
        `SELECT r.codigo AS rol, r.nombre, ur.organismo_id, ur.empresa_id, e.razon_social AS empresa,
                ur.comite_id, cm.nombre AS comite, ur.origen
           FROM usuario_rol ur
           JOIN rol r ON r.id = ur.rol_id
           LEFT JOIN empresa e ON e.id = ur.empresa_id
           LEFT JOIN comite cm ON cm.id = ur.comite_id
          WHERE ur.usuario_id = $1 AND ur.vigente
          ORDER BY ur.id`,
        [s.usuarioId],
      );
      return { ...u, roles };
    }),
  );

  app.get("/api/empresas", (req) =>
    ctx.tx(req, (c) =>
      varios(
        c,
        `SELECT e.id, e.rut, e.razon_social, e.nombre_fantasia, e.codigo_contrato, e.estado,
                e.actividad_economica_codigo, ae.seccion, e.organismo_id
           FROM empresa e LEFT JOIN actividad_economica ae ON ae.codigo = e.actividad_economica_codigo
          ORDER BY e.razon_social`,
      ),
    ),
  );

  app.get("/api/empresas/:id", (req) =>
    ctx.tx(req, async (c) => {
      const e = await uno(
        c,
        `SELECT e.id, e.rut, e.razon_social, e.nombre_fantasia, e.codigo_contrato, e.estado, e.plan,
                e.actividad_economica_codigo, ae.descripcion AS actividad, ae.seccion, e.organismo_id,
                e.fecha_alta
           FROM empresa e LEFT JOIN actividad_economica ae ON ae.codigo = e.actividad_economica_codigo
          WHERE e.id = $1`,
        [id(req)],
      );
      if (!e) throw noEncontrado("Empresa no encontrada");
      return e;
    }),
  );

  app.get("/api/empresas/:id/centros", (req) =>
    ctx.tx(req, (c) =>
      varios(
        c,
        `SELECT s.id, s.nombre, s.alias, s.direccion_calle, s.direccion_numero, s.comuna_id, co.nombre AS comuna,
                s.masa_trabajadores, s.estado, s.codigo_externo,
                (SELECT count(*) FROM comite cm WHERE cm.sucursal_id = s.id) AS comites
           FROM sucursal s LEFT JOIN comuna co ON co.id = s.comuna_id
          WHERE s.empresa_id = $1
          ORDER BY s.estado, s.nombre`,
        [id(req)],
      ),
    ),
  );

  app.post("/api/empresas/:id/centros", async (req, rep) => {
    const empresaId = id(req);
    const d = datos(centroNuevo, req.body);
    const nuevo = await ctx.tx(req, async (c, s) => {
      exigir(esAdminEmpresa(s, empresaId), "Solo el administrador de la empresa agrega centros");
      return insertar(c, "sucursal", { empresa_id: empresaId, ...d });
    });
    return rep.status(201).send({ id: nuevo });
  });

  app.patch("/api/centros/:id", (req) =>
    ctx.tx(req, async (c, s) => {
      const centroId = id(req);
      const d = datos(centroCambio, req.body);
      const centro = await uno<{ empresa_id: number; codigo_externo: string | null }>(
        c,
        "SELECT empresa_id, codigo_externo FROM sucursal WHERE id = $1",
        [centroId],
      );
      if (!centro) throw noEncontrado("Centro no encontrado");
      exigir(esAdminEmpresa(s, centro.empresa_id), "Solo el administrador de la empresa modifica centros");
      // Un centro sincronizado se actualiza desde el sistema del cliente: aquí solo cambia su alias.
      if (centro.codigo_externo && Object.keys(d).some((k) => k !== "alias")) {
        throw conflicto("El centro se actualiza desde el sistema del cliente: aquí solo se puede cambiar su alias");
      }
      await actualizar(c, "sucursal", centroId, d);
      return { id: centroId };
    }),
  );

  // Cumplimiento y paridad de los comités visibles. El organismo los ve de
  // todas sus empresas; la paridad le aparece sin integrantes (no ve personas).
  app.get("/api/indicadores", (req) =>
    ctx.tx(req, (c) => {
      const anio = Number((req.query as { anio?: string }).anio ?? new Date().getFullYear());
      return varios(
        c,
        `SELECT cm.id AS comite_id, cm.nombre AS comite, cm.empresa_id, e.razon_social AS empresa, cm.estado,
                coalesce(v.realizadas, 0) AS reuniones_realizadas, coalesce(v.exigidas, 0) AS reuniones_exigidas,
                coalesce(v.realizadas_sin_acta, 0) AS realizadas_sin_acta, v.porcentaje AS cumplimiento,
                p.es_paritario,
                (SELECT count(*) FROM actividad a WHERE a.comite_id = cm.id AND a.estado <> 'cerrado'
                   AND a.fecha_planificada < current_date) AS actividades_atrasadas
           FROM comite cm
           JOIN empresa e ON e.id = cm.empresa_id
           LEFT JOIN v_cumplimiento_reuniones v ON v.comite_id = cm.id AND v.anio = $1
           LEFT JOIN v_paridad_comite p ON p.comite_id = cm.id
          ORDER BY e.razon_social, cm.nombre`,
        [anio],
      );
    }),
  );

  app.get("/api/catalogos/comunas", (req) =>
    ctx.tx(req, (c) =>
      varios(
        c,
        `SELECT co.id, co.codigo, co.nombre, r.id AS region_id, r.nombre AS region
           FROM comuna co JOIN region r ON r.id = co.region_id ORDER BY r.orden, co.nombre`,
      ),
    ),
  );
}
