// Consultas compartidas por las rutas.

import type { Sesion } from "../auth.js";
import { uno, type Cliente } from "../db.js";
import { noEncontrado } from "../errores.js";
import { exigir, puedeEditarComite } from "../permisos.js";

export interface ComiteBase {
  id: number;
  empresa_id: number;
  estado: "activo" | "baja";
}

/** Comité visible para el usuario (seguridad por fila) o 404. */
export async function comiteVisible(c: Cliente, comiteId: number): Promise<ComiteBase> {
  const r = await uno<ComiteBase>(c, "SELECT id, empresa_id, estado FROM comite WHERE id = $1", [comiteId]);
  if (!r) throw noEncontrado("Comité no encontrado");
  return r;
}

/** Comité visible, activo y que el usuario puede editar. */
export async function comiteEditable(c: Cliente, s: Sesion, comiteId: number): Promise<ComiteBase> {
  const r = await comiteVisible(c, comiteId);
  exigir(puedeEditarComite(s, r), "Solo el administrador de la empresa o el coordinador del comité pueden modificarlo");
  exigir(r.estado === "activo", "El comité está de baja");
  return r;
}
