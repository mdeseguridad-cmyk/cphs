// Sesión del usuario: quién es, sus accesos y la empresa con que trabaja.
// Los permisos replican los de la API (api/src/permisos.ts) solo para
// mostrar u ocultar acciones: quien decide es siempre la API.

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { api } from "./api";

export interface Acceso {
  rol: "ADMIN_ORGANISMO" | "ASESOR_ORGANISMO" | "ADMIN_EMPRESA" | "COORDINADOR" | "AUDITOR";
  nombre: string;
  organismo_id: number | null;
  empresa_id: number | null;
  empresa: string | null;
  comite_id: number | null;
  comite: string | null;
  origen: "manual" | "solicitud" | "sso";
}

export interface Yo {
  id: number;
  rut: string;
  estado: string;
  nombres: string | null;
  apellidos: string | null;
  email: string | null;
  roles: Acceso[];
}

export interface Empresa {
  id: number;
  rut: string;
  razon_social: string;
  nombre_fantasia: string | null;
  codigo_contrato: string | null;
  estado: string;
  seccion: string | null;
  organismo_id: number | null;
}

interface ValorSesion {
  yo: Yo;
  empresas: Empresa[];
  /** Empresa con que trabaja; null = todas (organismo). */
  empresaId: number | null;
  elegirEmpresa(id: number | null): void;
  esOrganismo: boolean;
  esAdmin(empresaId: number | null): boolean;
  puedeEditarComite(c: { id: number; empresa_id: number; estado?: string }): boolean;
  salir(): void;
}

const Contexto = createContext<ValorSesion | null>(null);
const CLAVE_EMPRESA = "paritario.empresa";

export function ProveedorSesion(p: { yo: Yo; empresas: Empresa[]; salir(): void; children: ReactNode }) {
  const { yo, empresas } = p;
  const esOrganismo = yo.roles.some((r) => r.organismo_id !== null);
  const inicial = (() => {
    const guardada = Number(sessionStorage.getItem(CLAVE_EMPRESA));
    if (empresas.some((e) => e.id === guardada)) return guardada;
    if (esOrganismo) return null;
    return empresas[0]?.id ?? null;
  })();
  const [empresaId, setEmpresaId] = useState<number | null>(inicial);

  const elegirEmpresa = useCallback((id: number | null) => {
    setEmpresaId(id);
    if (id === null) sessionStorage.removeItem(CLAVE_EMPRESA);
    else sessionStorage.setItem(CLAVE_EMPRESA, String(id));
  }, []);

  const valor = useMemo<ValorSesion>(
    () => ({
      yo,
      empresas,
      empresaId,
      elegirEmpresa,
      esOrganismo,
      esAdmin: (id) => id !== null && yo.roles.some((r) => r.rol === "ADMIN_EMPRESA" && r.empresa_id === id),
      puedeEditarComite: (c) =>
        c.estado !== "baja" &&
        yo.roles.some(
          (r) =>
            r.empresa_id === c.empresa_id &&
            (r.rol === "ADMIN_EMPRESA" || (r.rol === "COORDINADOR" && (r.comite_id === null || r.comite_id === c.id))),
        ),
      salir: p.salir,
    }),
    [yo, empresas, empresaId, elegirEmpresa, esOrganismo, p.salir],
  );
  return <Contexto.Provider value={valor}>{p.children}</Contexto.Provider>;
}

export function useSesion(): ValorSesion {
  const v = useContext(Contexto);
  if (!v) throw new Error("useSesion fuera de ProveedorSesion");
  return v;
}

/** Carga la sesión desde la API. */
export async function cargarSesion(): Promise<{ yo: Yo; empresas: Empresa[] }> {
  const [yo, empresas] = await Promise.all([api<Yo>("GET", "/api/yo"), api<Empresa[]>("GET", "/api/empresas")]);
  return { yo, empresas };
}

export const NOMBRE_ROL: Record<Acceso["rol"], string> = {
  ADMIN_ORGANISMO: "Administrador de organismo",
  ASESOR_ORGANISMO: "Asesor de organismo",
  ADMIN_EMPRESA: "Administrador",
  COORDINADOR: "Coordinador",
  AUDITOR: "Auditor",
};

export function useRecarga(): [number, () => void] {
  const [n, setN] = useState(0);
  return [n, useCallback(() => setN((x) => x + 1), [])];
}

export function useTitulo(titulo: string): void {
  useEffect(() => {
    document.title = `${titulo} · Paritario`;
  }, [titulo]);
}
