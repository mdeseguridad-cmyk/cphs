import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { ErrorApi } from "./api";

export function Chip(p: { tono?: "ok" | "warn" | "crit" | "acento"; children: ReactNode }) {
  return <span className={`chip ${p.tono ?? ""}`}>{p.children}</span>;
}

export function Cargando() {
  return <div className="cargando" role="status">Cargando…</div>;
}

export function AvisoError(p: { error: unknown }) {
  if (!p.error) return null;
  const e = p.error instanceof ErrorApi ? p.error : null;
  return (
    <div className="aviso error" role="alert">
      <div>
        {e?.message ?? String((p.error as Error)?.message ?? p.error)}
        {e?.detalle?.length ? (
          <ul>
            {e.detalle.map((d, i) => (
              <li key={i}>{d.campo ? `${d.campo}: ` : ""}{d.mensaje}</li>
            ))}
          </ul>
        ) : null}
      </div>
    </div>
  );
}

export function Encabezado(p: { titulo: string; sub?: ReactNode; children?: ReactNode }) {
  return (
    <div className="ph">
      <div>
        <h1>{p.titulo}</h1>
        {p.sub ? <p>{p.sub}</p> : null}
      </div>
      {p.children ? <div className="acciones">{p.children}</div> : null}
    </div>
  );
}

export function Campo(p: { etiqueta: string; id: string; ayuda?: ReactNode; error?: string; completo?: boolean; children: ReactNode }) {
  return (
    <div className={`campo ${p.completo ? "completo" : ""}`}>
      <label htmlFor={p.id}>{p.etiqueta}</label>
      {p.children}
      {p.error ? <span className="error">{p.error}</span> : p.ayuda ? <span className="ayuda">{p.ayuda}</span> : null}
    </div>
  );
}

/**
 * Diálogo con formulario. onEnviar puede fallar: el error se muestra dentro
 * del diálogo y este queda abierto.
 */
export function Dialogo(p: {
  titulo: string;
  boton: string;
  peligro?: boolean;
  onCerrar(): void;
  onEnviar(): Promise<void>;
  children: ReactNode;
}) {
  const [error, setError] = useState<unknown>(null);
  const [enviando, setEnviando] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const cerrar = useRef(p.onCerrar);
  cerrar.current = p.onCerrar;
  // Solo al abrir: foco en el primer campo y Escape para cerrar.
  useEffect(() => {
    ref.current?.querySelector<HTMLElement>("input, select, textarea")?.focus();
    const esc = (e: KeyboardEvent) => e.key === "Escape" && cerrar.current();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, []);
  async function enviar(e: FormEvent) {
    e.preventDefault();
    setEnviando(true);
    setError(null);
    try {
      await p.onEnviar();
    } catch (err) {
      setError(err);
      setEnviando(false);
    }
  }
  return (
    <div className="fondo" onMouseDown={(e) => e.target === e.currentTarget && p.onCerrar()}>
      <div className="dialogo" role="dialog" aria-modal="true" aria-label={p.titulo} ref={ref}>
        <form onSubmit={enviar}>
          <header>
            <h2>{p.titulo}</h2>
            <button type="button" className="btn sec chico" onClick={p.onCerrar} aria-label="Cerrar">✕</button>
          </header>
          <div className="cuerpo">
            <AvisoError error={error} />
            {p.children}
          </div>
          <footer>
            <button type="button" className="btn sec" onClick={p.onCerrar}>Cancelar</button>
            <button type="submit" className={`btn ${p.peligro ? "peligro" : ""}`} disabled={enviando}>
              {enviando ? "Guardando…" : p.boton}
            </button>
          </footer>
        </form>
      </div>
    </div>
  );
}

export const icono = {
  panel: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9"><rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/></svg>,
  comites: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9"><circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><circle cx="17.5" cy="9" r="2.5"/><path d="M16 14.5a5 5 0 0 1 6 5"/></svg>,
  centros: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9"><path d="M3 21V7l9-4 9 4v14"/><path d="M9 21v-6h6v6"/></svg>,
  usuarios: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>,
  bitacora: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9"><path d="M6 3h9l4 4v14H6z"/><path d="M14 3v5h5"/><path d="M9 12h7M9 16h5"/></svg>,
  mas: <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M12 5v14M5 12h14"/></svg>,
  menu: <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="2"><path d="M4 7h16M4 12h16M4 17h16"/></svg>,
  logo: <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2"><path d="M12 3l7 3v5c0 4.4-3 7.6-7 9-4-1.4-7-4.6-7-9V6l7-3z"/><path d="M9 12l2 2 4-4"/></svg>,
};
