// Usuarios y accesos de una empresa. Paritario no guarda contraseñas: la
// cuenta la crea Cognito, que envía la invitación con una clave temporal. La
// API no tiene internet: deja un trabajo que ejecuta la función de trabajos.

import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Contexto } from "../app.js";
import { datos, id, rut } from "../validacion.js";
import type { Sesion } from "../auth.js";
import { actualizar, insertar, uno, varios, type Cliente } from "../db.js";
import { conflicto, noEncontrado } from "../errores.js";
import { esAdminEmpresa, exigir } from "../permisos.js";
import { encolarTrabajo } from "../servicios.js";

const invitacion = z.object({
  rut,
  nombres: z.string().trim().min(1).max(120),
  apellidos: z.string().trim().min(1).max(120),
  correo: z.string().email().max(160),
  rol: z.enum(["ADMIN_EMPRESA", "COORDINADOR", "AUDITOR"]),
  comite_id: z.number().int().positive().optional(),
});

/**
 * Un administrador puede bloquear o desbloquear una cuenta solo si todos sus
 * accesos vigentes son en empresas que él administra: si la persona trabaja
 * también para otra empresa, corresponde quitarle el acceso, no bloquearla.
 */
async function cuentaAdministrable(c: Cliente, s: Sesion, usuarioId: number) {
  exigir(usuarioId !== s.usuarioId, "No puede bloquear su propia cuenta");
  const u = await uno<{ id: number; rut: string; estado: string; cognito_sub: string | null }>(
    c,
    "SELECT id, rut, estado, cognito_sub FROM usuario WHERE id = $1",
    [usuarioId],
  );
  if (!u) throw noEncontrado("Usuario no encontrado");
  const roles = await varios<{ empresa_id: number | null }>(c, "SELECT empresa_id FROM usuario_rol WHERE usuario_id = $1 AND vigente", [usuarioId]);
  exigir(roles.length > 0, "Solo se administran cuentas con acceso a su empresa");
  exigir(
    roles.every((r) => r.empresa_id !== null && esAdminEmpresa(s, r.empresa_id)),
    "La persona tiene acceso a otras empresas: quítele el acceso a la suya en vez de bloquear la cuenta",
  );
  return u;
}

export function rutasUsuarios(app: FastifyInstance, ctx: Contexto): void {
  app.get("/api/empresas/:id/usuarios", (req) =>
    ctx.tx(req, async (c, s) => {
      const empresaId = id(req);
      exigir(esAdminEmpresa(s, empresaId), "Solo el administrador de la empresa ve sus usuarios");
      return varios(
        c,
        `SELECT u.id, u.rut, u.estado, u.mfa_habilitado, u.ultimo_acceso, p.nombres, p.apellidos, p.email,
                json_agg(json_build_object('acceso_id', ur.id, 'rol', r.codigo, 'comite_id', ur.comite_id,
                                           'comite', cm.nombre, 'origen', ur.origen) ORDER BY ur.id) AS accesos
           FROM usuario_rol ur
           JOIN usuario u ON u.id = ur.usuario_id
           JOIN rol r ON r.id = ur.rol_id
           LEFT JOIN persona p ON p.id = u.persona_id
           LEFT JOIN comite cm ON cm.id = ur.comite_id
          WHERE ur.empresa_id = $1 AND ur.vigente
          GROUP BY u.id, p.nombres, p.apellidos, p.email
          ORDER BY p.apellidos NULLS LAST, u.rut`,
        [empresaId],
      );
    }),
  );

  app.post("/api/empresas/:id/usuarios", async (req, rep) => {
    const empresaId = id(req);
    const d = datos(invitacion, req.body);
    const r = await ctx.tx(req, async (c, s) => {
      exigir(esAdminEmpresa(s, empresaId), "Solo el administrador de la empresa invita usuarios");
      const persona = await uno<{ id: number }>(c, "SELECT asegurar_persona($1, $2, $3, $4) AS id", [d.rut, d.nombres, d.apellidos, d.correo]);
      let u = await uno<{ id: number; estado: string }>(c, "SELECT id, estado FROM usuario WHERE rut = $1", [d.rut]);
      let invitado = false;
      if (!u) {
        const nuevo = await insertar(c, "usuario", { rut: d.rut, persona_id: persona!.id, estado: "invitado" });
        u = { id: nuevo, estado: "invitado" };
        invitado = true;
      }
      const rolId = (await uno<{ id: number }>(c, "SELECT id FROM rol WHERE codigo = $1", [d.rol]))!.id;
      const repetido = await uno(
        c,
        "SELECT 1 FROM usuario_rol WHERE usuario_id = $1 AND rol_id = $2 AND empresa_id = $3 AND comite_id IS NOT DISTINCT FROM $4 AND vigente",
        [u.id, rolId, empresaId, d.comite_id ?? null],
      );
      if (repetido) throw conflicto("La persona ya tiene ese acceso");
      const accesoId = await insertar(c, "usuario_rol", {
        usuario_id: u.id,
        rol_id: rolId,
        empresa_id: empresaId,
        comite_id: d.comite_id,
        origen: "manual",
      });
      if (invitado) await encolarTrabajo(ctx.cfg, ctx.servicios, "crear_usuario", { rut: d.rut, correo: d.correo });
      return { usuario_id: u.id, acceso_id: accesoId, invitacion_enviada: invitado, estado: u.estado };
    });
    return rep.status(201).send(r);
  });

  app.post("/api/usuarios/:id/reenviar", (req) =>
    ctx.tx(req, async (c, s) => {
      const u = await cuentaAdministrable(c, s, id(req));
      if (u.estado !== "invitado") throw conflicto("La persona ya ingresó: no hay invitación pendiente");
      await encolarTrabajo(ctx.cfg, ctx.servicios, "reenviar_invitacion", { rut: u.rut });
      return { id: u.id };
    }),
  );

  app.post("/api/usuarios/:id/bloquear", (req) =>
    ctx.tx(req, async (c, s) => {
      const u = await cuentaAdministrable(c, s, id(req));
      if (u.estado === "bloqueado") return { id: u.id, estado: "bloqueado" };
      await actualizar(c, "usuario", u.id, { estado: "bloqueado" });
      await encolarTrabajo(ctx.cfg, ctx.servicios, "bloquear", { rut: u.rut });
      return { id: u.id, estado: "bloqueado" };
    }),
  );

  app.post("/api/usuarios/:id/desbloquear", (req) =>
    ctx.tx(req, async (c, s) => {
      const u = await cuentaAdministrable(c, s, id(req));
      if (u.estado !== "bloqueado") return { id: u.id, estado: u.estado };
      const estado = u.cognito_sub ? "activo" : "invitado";
      await actualizar(c, "usuario", u.id, { estado });
      await encolarTrabajo(ctx.cfg, ctx.servicios, "desbloquear", { rut: u.rut });
      return { id: u.id, estado };
    }),
  );

  // Quitar un acceso: se marca no vigente, nunca se borra.
  app.delete("/api/accesos/:id", (req) =>
    ctx.tx(req, async (c, s) => {
      const accesoId = id(req);
      const a = await uno<{ empresa_id: number | null; origen: string; usuario_id: number }>(
        c,
        "SELECT empresa_id, origen, usuario_id FROM usuario_rol WHERE id = $1 AND vigente",
        [accesoId],
      );
      if (!a || a.empresa_id === null) throw noEncontrado("Acceso no encontrado");
      exigir(esAdminEmpresa(s, a.empresa_id), "Solo el administrador de la empresa quita accesos");
      if (a.origen === "sso") throw conflicto("Este acceso lo entrega el sistema del cliente: se quita allá o bloqueando la cuenta");
      await actualizar(c, "usuario_rol", accesoId, { vigente: false });
      return { id: accesoId, vigente: false };
    }),
  );
}
