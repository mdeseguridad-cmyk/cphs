import { useEffect, useState } from "react";
import { ErrorApi } from "./api";

/** RUT sin puntos, con guion y K mayúscula: el formato de la base. */
export function normalizarRut(v: string): string {
  return v.replace(/[.\s]/g, "").toUpperCase();
}

export function rutValido(v: string): boolean {
  const r = normalizarRut(v);
  const m = /^(\d{6,8})-([\dK])$/.exec(r);
  if (!m) return false;
  let s = 0;
  let f = 2;
  for (const d of m[1]!.split("").reverse()) {
    s += Number(d) * f;
    f = f === 7 ? 2 : f + 1;
  }
  const v11 = 11 - (s % 11);
  return m[2] === (v11 === 11 ? "0" : v11 === 10 ? "K" : String(v11));
}

/** 12345678-5 → 12.345.678-5 */
export function formatoRut(v: string): string {
  const [c, dv] = normalizarRut(v).split("-");
  if (!c || !dv) return v;
  return `${c.replace(/\B(?=(\d{3})+(?!\d))/g, ".")}-${dv}`;
}

const MESES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];
export const NOMBRES_MES = ["Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio", "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre"];

/** 2026-03-09 → 9 mar 2026 */
export function formatoFecha(v: string | null | undefined): string {
  if (!v) return "—";
  const [a, m, d] = v.slice(0, 10).split("-");
  return `${Number(d)} ${MESES[Number(m) - 1]} ${a}`;
}

export function hoy(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

export function formatoTamano(b: number): string {
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(0)} KB`;
  return `${(b / 1024 / 1024).toFixed(1)} MB`;
}

export interface Datos<T> {
  datos: T | null;
  error: ErrorApi | null;
  cargando: boolean;
}

/** Carga datos de la API y vuelve a cargar cuando cambian las dependencias. */
export function useDatos<T>(cargar: () => Promise<T>, deps: unknown[]): Datos<T> {
  const [estado, setEstado] = useState<Datos<T>>({ datos: null, error: null, cargando: true });
  useEffect(() => {
    let vigente = true;
    setEstado((e) => ({ ...e, cargando: true, error: null }));
    cargar().then(
      (datos) => vigente && setEstado({ datos, error: null, cargando: false }),
      (error: unknown) =>
        vigente && setEstado({ datos: null, error: error instanceof ErrorApi ? error : new ErrorApi(0, "error", String(error)), cargando: false }),
    );
    return () => {
      vigente = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return estado;
}
