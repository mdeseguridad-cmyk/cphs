// Qué puede editar cada rol dentro de su ámbito. Qué puede VER lo decide la
// base de datos (seguridad por fila); estas reglas deciden qué puede CAMBIAR.
//
//   Administrador de empresa  todo en su empresa: centros, comités, usuarios.
//   Coordinador               integrantes, comisiones, programa, reuniones y
//                             actas de su comité (o de todos, si no tiene uno).
//   Auditor                   solo lectura (las auditorías son de la fase 3).
//   Roles de organismo        solo lectura de indicadores.

import type { Sesion } from "./auth.js";
import { prohibido } from "./errores.js";

export function esAdminEmpresa(s: Sesion, empresaId: number): boolean {
  return s.roles.some((r) => r.codigo === "ADMIN_EMPRESA" && r.empresaId === empresaId);
}

export function puedeEditarComite(s: Sesion, comite: { id: number; empresa_id: number }): boolean {
  return s.roles.some(
    (r) =>
      r.empresaId === comite.empresa_id &&
      (r.codigo === "ADMIN_EMPRESA" || (r.codigo === "COORDINADOR" && (r.comiteId === null || r.comiteId === comite.id))),
  );
}

export function exigir(condicion: boolean, mensaje?: string): void {
  if (!condicion) throw prohibido(mensaje);
}
