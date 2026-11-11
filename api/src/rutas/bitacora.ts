// Consulta de la bitácora de accesos a datos personales (Ley 21.719). Solo la
// ve el administrador de la empresa: lo exige esta ruta y, además, la
// seguridad por fila de log_acceso (empresas_administradas()).
//
// Cada entrada se describe con lo que la persona vio o cambió: el integrante,
// la reunión o el documento, y su comité. Descargar la bitácora queda, a su
// vez, registrado en ella (acción "exportar").

import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Contexto } from "../app.js";
import { datos, fecha, id } from "../validacion.js";
import { ORIGEN_SQL, varios, type Cliente } from "../db.js";
import { exigir, esAdminEmpresa } from "../permisos.js";
import { invalido } from "../errores.js";

const entero = z.coerce.number().int().positive();

const filtros = z.object({
  desde: fecha.optional(),
  hasta: fecha.optional(),
  usuario_id: entero.optional(),
  comite_id: entero.optional(),
  accion: z.enum(["ver", "crear", "editar", "eliminar", "exportar"]).optional(),
  /** Página siguiente: entradas con id menor que este. */
  antes: entero.optional(),
  limite: z.coerce.number().int().min(1).max(200).default(50),
});
type Filtros = z.infer<typeof filtros>;

/** Máximo de entradas en una descarga. */
const MAX_DESCARGA = 10_000;

export interface EntradaBitacora {
  id: number;
  fecha: string;
  accion: string;
  entidad: string | null;
  entidad_id: number | null;
  usuario_id: number | null;
  rut: string | null;
  nombres: string | null;
  apellidos: string | null;
  comite_id: number | null;
  comite: string | null;
  detalle: string | null;
  ip: string | null;
  navegador: string | null;
}

async function consultar(c: Cliente, empresaId: number, f: Filtros, limite: number): Promise<EntradaBitacora[]> {
  if (f.desde && f.hasta && f.desde > f.hasta) throw invalido("La fecha inicial es posterior a la final");
  const cond = ["l.empresa_id = $1"];
  const p: unknown[] = [empresaId];
  const agregar = (sql: string, v: unknown) => {
    p.push(v);
    cond.push(sql.replace("?", `$${p.length}`));
  };
  // Los días se cuentan en hora de Chile.
  if (f.desde) agregar(`l."timestamp" >= (?::date)::timestamp AT TIME ZONE 'America/Santiago'`, f.desde);
  if (f.hasta) agregar(`l."timestamp" < (?::date + 1)::timestamp AT TIME ZONE 'America/Santiago'`, f.hasta);
  if (f.usuario_id) agregar("l.usuario_id = ?", f.usuario_id);
  if (f.accion) agregar("l.accion = ?::log_accion", f.accion);
  if (f.comite_id) agregar("cm.id = ?", f.comite_id);
  if (f.antes) agregar("l.id < ?", f.antes);
  p.push(limite);
  return varios<EntradaBitacora>(
    c,
    `SELECT l.id, to_char(l."timestamp" AT TIME ZONE 'America/Santiago', 'YYYY-MM-DD"T"HH24:MI:SS') AS fecha,
            l.accion::text AS accion, l.entidad, l.entidad_id, l.usuario_id,
            u.rut, p.nombres, p.apellidos, cm.id AS comite_id, cm.nombre AS comite,
            host(l.ip) AS ip, l.user_agent AS navegador,
            CASE l.entidad
              WHEN 'comite_integrante'  THEN concat_ws(' ', pi.nombres, pi.apellidos)
              WHEN 'documento'          THEN d.nombre
              WHEN 'reunion_asistencia' THEN format('Reunión N° %s (%s/%s)', r.numero, r.mes, r.anio)
              WHEN 'log_acceso'         THEN 'Descarga de la bitácora'
            END AS detalle
       FROM log_acceso l
       LEFT JOIN usuario u            ON u.id = l.usuario_id
       LEFT JOIN persona p            ON p.id = u.persona_id
       LEFT JOIN comite_integrante ci ON l.entidad = 'comite_integrante' AND ci.id = l.entidad_id
       LEFT JOIN persona pi           ON pi.id = ci.persona_id
       LEFT JOIN documento d          ON l.entidad = 'documento' AND d.id = l.entidad_id
       LEFT JOIN reunion r            ON l.entidad = 'reunion_asistencia' AND r.id = l.entidad_id
       LEFT JOIN comite cm            ON cm.id = CASE l.entidad
                                                   WHEN 'comite'             THEN l.entidad_id
                                                   WHEN 'comite_integrante'  THEN ci.comite_id
                                                   WHEN 'documento'          THEN d.comite_id
                                                   WHEN 'reunion_asistencia' THEN r.comite_id
                                                 END
      WHERE ${cond.join(" AND ")}
      ORDER BY l.id DESC
      LIMIT $${p.length}`,
    p,
  );
}

const NOMBRE_ENTIDAD: Record<string, string> = {
  comite: "Integrantes del comité",
  comite_integrante: "Integrante",
  reunion_asistencia: "Asistencia a reunión",
  documento: "Documento",
  log_acceso: "Bitácora",
};

/** Una celda CSV. Neutraliza fórmulas (=, +, -, @) para que una planilla no las ejecute. */
function celda(v: unknown): string {
  let s = v === null || v === undefined ? "" : String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[";\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function rutasBitacora(app: FastifyInstance, ctx: Contexto): void {
  const soloAdmin = "Solo el administrador de la empresa consulta su bitácora de accesos";

  app.get("/api/empresas/:id/bitacora", (req) =>
    ctx.tx(req, async (c, s) => {
      const empresaId = id(req);
      exigir(esAdminEmpresa(s, empresaId), soloAdmin);
      const f = datos(filtros, req.query);
      const filas = await consultar(c, empresaId, f, f.limite + 1);
      const hayMas = filas.length > f.limite;
      const entradas = hayMas ? filas.slice(0, f.limite) : filas;
      return { entradas, siguiente: hayMas ? entradas[entradas.length - 1]!.id : null };
    }),
  );

  // Personas que aparecen en la bitácora, para el filtro (incluye a quienes ya no tienen acceso).
  app.get("/api/empresas/:id/bitacora/usuarios", (req) =>
    ctx.tx(req, async (c, s) => {
      const empresaId = id(req);
      exigir(esAdminEmpresa(s, empresaId), soloAdmin);
      return varios(
        c,
        `SELECT u.id, u.rut, p.nombres, p.apellidos
           FROM (SELECT DISTINCT usuario_id FROM log_acceso WHERE empresa_id = $1) l
           JOIN usuario u ON u.id = l.usuario_id
           LEFT JOIN persona p ON p.id = u.persona_id
          ORDER BY p.apellidos NULLS LAST, u.rut`,
        [empresaId],
      );
    }),
  );

  app.get("/api/empresas/:id/bitacora.csv", async (req, rep) => {
    const empresaId = id(req);
    const csv = await ctx.tx(req, async (c, s) => {
      exigir(esAdminEmpresa(s, empresaId), soloAdmin);
      const f = datos(filtros, req.query);
      const filas = await consultar(c, empresaId, { ...f, antes: undefined }, MAX_DESCARGA);
      await c.query(
        `INSERT INTO log_acceso (usuario_id, empresa_id, accion, entidad, ip, user_agent)
         VALUES ($1, $2, 'exportar', 'log_acceso', ${ORIGEN_SQL})`,
        [s.usuarioId, empresaId],
      );
      const lineas = [
        ["Fecha (hora de Chile)", "RUT", "Persona", "Acción", "Sobre", "Detalle", "Comité", "IP", "Navegador"].join(";"),
        ...filas.map((e) =>
          [e.fecha.replace("T", " "), e.rut, [e.nombres, e.apellidos].filter(Boolean).join(" "), e.accion,
            NOMBRE_ENTIDAD[e.entidad ?? ""] ?? e.entidad, e.detalle, e.comite, e.ip, e.navegador]
            .map(celda)
            .join(";"),
        ),
      ];
      // BOM para que Excel reconozca los acentos.
      return "﻿" + lineas.join("\r\n") + "\r\n";
    });
    return rep
      .header("content-type", "text/csv; charset=utf-8")
      .header("content-disposition", `attachment; filename="bitacora-accesos-${new Date().toISOString().slice(0, 10)}.csv"`)
      .header("cache-control", "no-store")
      .send(csv);
  });
}
