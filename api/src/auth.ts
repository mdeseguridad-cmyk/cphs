// Autenticación: token de Cognito (id token) en el encabezado X-Token-Usuario.
// CloudFront usa Authorization para firmar la llamada a la función, por eso
// el token va en otro encabezado. En desarrollo también se acepta
// Authorization: Bearer.
//
// En el primer uso de cada token se registra el ingreso en la base:
//   - cuenta propia de Paritario → registrar_ingreso(rut, sub)
//   - sistema de un cliente (SSO) → ingresar_sso(proveedor, rut, sub, rol, contratos),
//     que concilia los accesos que entrega ese sistema.

import { readFileSync } from "node:fs";
import { createLocalJWKSet, jwtVerify, type JWTVerifyGetKey, type JWTPayload } from "jose";
import type pg from "pg";
import type { Config } from "./config.js";
import { enTransaccion, varios } from "./db.js";
import { noAutenticado } from "./errores.js";

export interface RolSesion {
  id: number;
  codigo: "ADMIN_ORGANISMO" | "ASESOR_ORGANISMO" | "ADMIN_EMPRESA" | "COORDINADOR" | "AUDITOR";
  organismoId: number | null;
  empresaId: number | null;
  comiteId: number | null;
  origen: "manual" | "solicitud" | "sso";
}

export interface Sesion {
  usuarioId: number;
  roles: RolSesion[];
}

export interface Reclamos {
  sub: string;
  usuario: string;
  rut: string | null;
  rolExterno: string | null;
  contratos: string[];
  proveedor: string | null;
  emitido: number;
}

export type VerificarToken = (token: string) => Promise<Reclamos>;

function leerReclamos(p: JWTPayload): Reclamos {
  if (p.token_use !== "id") throw noAutenticado("Se espera el token de identidad de Cognito");
  let identidades = p.identities as unknown;
  if (typeof identidades === "string") {
    try {
      identidades = JSON.parse(identidades);
    } catch {
      identidades = [];
    }
  }
  const proveedor = Array.isArray(identidades) ? ((identidades[0] as { providerName?: string })?.providerName ?? null) : null;
  const contratos = String(p["custom:contratos"] ?? "")
    .split(/[\s,;]+/)
    .map((c) => c.trim())
    .filter(Boolean);
  return {
    sub: String(p.sub),
    usuario: String(p["cognito:username"] ?? ""),
    rut: (p["custom:rut"] as string | undefined) ?? null,
    rolExterno: (p["custom:rol_externo"] as string | undefined) ?? null,
    contratos,
    proveedor,
    emitido: Number(p.iat ?? 0),
  };
}

/** Verificador con el JWKS del user pool incluido en la imagen. */
export function verificadorCognito(cfg: Config, jwks?: JWTVerifyGetKey): VerificarToken {
  const claves = jwks ?? createLocalJWKSet(JSON.parse(readFileSync(cfg.cognito.jwksPath, "utf8")));
  return async (token) => {
    try {
      const { payload } = await jwtVerify(token, claves, {
        issuer: cfg.cognito.emisor,
        audience: cfg.cognito.clientId,
      });
      return leerReclamos(payload);
    } catch (e) {
      if ((e as { status?: number }).status === 401) throw e;
      throw noAutenticado("Token inválido o vencido");
    }
  };
}

export function tokenDeSolicitud(h: Record<string, string | string[] | undefined>): string | null {
  const t = h["x-token-usuario"];
  if (typeof t === "string" && t) return t;
  const a = h.authorization;
  if (typeof a === "string" && a.startsWith("Bearer ")) return a.slice(7);
  return null;
}

// Un ingreso por token: el SSO se concilia cuando el usuario obtiene un token nuevo.
const ingresos = new Map<string, { usuarioId: number; vence: number }>();

// Ingresos en curso: solicitudes simultáneas con el mismo token comparten uno.
const enCurso = new Map<string, Promise<number>>();

export async function resolverUsuario(pool: pg.Pool, r: Reclamos): Promise<number> {
  const clave = `${r.sub}:${r.emitido}`;
  const ahora = Date.now();
  const enCache = ingresos.get(clave);
  if (enCache && enCache.vence > ahora) return enCache.usuarioId;
  const pendiente = enCurso.get(clave);
  if (pendiente) return pendiente;
  const p = registrar(pool, r, clave).finally(() => enCurso.delete(clave));
  enCurso.set(clave, p);
  return p;
}

async function registrar(pool: pg.Pool, r: Reclamos, clave: string): Promise<number> {
  const ahora = Date.now();
  const usuarioId = await enTransaccion(pool, null, async (c) => {
    if (r.proveedor) {
      const rows = await varios<{ id: number }>(c, "SELECT ingresar_sso($1, $2, $3, $4, $5) AS id", [
        r.proveedor,
        r.rut ?? "",
        r.sub,
        r.rolExterno ?? "",
        r.contratos,
      ]);
      return rows[0]!.id;
    }
    const rows = await varios<{ id: number }>(c, "SELECT registrar_ingreso($1, $2) AS id", [r.usuario, r.sub]);
    return rows[0]!.id;
  });

  if (ingresos.size > 5000) ingresos.clear();
  ingresos.set(clave, { usuarioId, vence: ahora + 10 * 60_000 });
  return usuarioId;
}

/** Olvida los ingresos en caché (al bloquear un usuario, o en pruebas). */
export function olvidarIngresos(): void {
  ingresos.clear();
}

export async function cargarSesion(c: pg.PoolClient, usuarioId: number): Promise<Sesion> {
  const u = await varios<{ estado: string }>(c, "SELECT estado FROM usuario WHERE id = $1", [usuarioId]);
  if (!u[0] || u[0].estado === "bloqueado") throw noAutenticado("La cuenta está bloqueada");
  const roles = await varios<RolSesion>(
    c,
    `SELECT ur.id, r.codigo, ur.organismo_id AS "organismoId", ur.empresa_id AS "empresaId",
            ur.comite_id AS "comiteId", ur.origen
       FROM usuario_rol ur JOIN rol r ON r.id = ur.rol_id
      WHERE ur.usuario_id = $1 AND ur.vigente`,
    [usuarioId],
  );
  return { usuarioId, roles };
}
