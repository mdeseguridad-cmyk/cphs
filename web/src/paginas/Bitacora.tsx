import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { api, descargar, ErrorApi } from "../api";
import { AvisoError, Cargando, Chip, Encabezado } from "../componentes";
import { useSesion, useTitulo } from "../sesion";
import { formatoFecha, formatoRut, hoy, useDatos } from "../util";
import type { ComiteFila } from "./Comites";

interface Entrada {
  id: number;
  fecha: string;
  accion: "ver" | "crear" | "editar" | "eliminar" | "exportar";
  entidad: string | null;
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

interface Pagina {
  entradas: Entrada[];
  siguiente: number | null;
}

interface Actor {
  id: number;
  rut: string;
  nombres: string | null;
  apellidos: string | null;
}

const ACCION: Record<Entrada["accion"], [string, "ok" | "warn" | "crit" | "acento" | undefined]> = {
  ver: ["Vio", undefined],
  crear: ["Creó", "ok"],
  editar: ["Editó", "acento"],
  eliminar: ["Eliminó", "crit"],
  exportar: ["Descargó", "warn"],
};

const ENTIDAD: Record<string, string> = {
  comite: "Integrantes del comité",
  comite_integrante: "Integrante",
  reunion_asistencia: "Asistencia a reunión",
  documento: "Documento",
  log_acceso: "Bitácora de accesos",
};

/** Fecha de hace n días, AAAA-MM-DD (hora local). */
function haceDias(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** "Chrome · Windows" a partir del User-Agent; el texto completo queda en el título. */
export function navegadorCorto(ua: string | null): string {
  if (!ua) return "";
  const nav = /Edg\//.test(ua) ? "Edge" : /OPR\//.test(ua) ? "Opera" : /Firefox\//.test(ua) ? "Firefox"
    : /Chrome\/|CriOS\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "";
  const so = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS" : /Windows/.test(ua) ? "Windows"
    : /Mac OS X|Macintosh/.test(ua) ? "macOS" : /Linux/.test(ua) ? "Linux" : "";
  return [nav, so].filter(Boolean).join(" · ") || "Otro";
}

const nombreDe = (a: { nombres: string | null; apellidos: string | null; rut: string | null }) =>
  [a.nombres, a.apellidos].filter(Boolean).join(" ") || (a.rut ? formatoRut(a.rut) : "—");

export function Bitacora() {
  useTitulo("Bitácora de accesos");
  const s = useSesion();
  const empresaId = s.empresaId!;
  const [f, setF] = useState({ desde: haceDias(30), hasta: hoy(), usuario_id: "", comite_id: "", accion: "" });
  const [pagina, setPagina] = useState<Pagina | null>(null);
  const [cargando, setCargando] = useState(true);
  const [masCargando, setMasCargando] = useState(false);
  const [descargando, setDescargando] = useState(false);
  const [error, setError] = useState<unknown>(null);

  const actores = useDatos(() => api<Actor[]>("GET", `/api/empresas/${empresaId}/bitacora/usuarios`), [empresaId]);
  const comites = useDatos(() => api<ComiteFila[]>("GET", `/api/comites?empresa_id=${empresaId}`), [empresaId]);

  const consulta = new URLSearchParams(Object.entries(f).filter(([, v]) => v !== "")).toString();

  useEffect(() => {
    let vigente = true;
    setCargando(true);
    setError(null);
    api<Pagina>("GET", `/api/empresas/${empresaId}/bitacora?${consulta}`).then(
      (p) => vigente && (setPagina(p), setCargando(false)),
      (e: unknown) => vigente && (setError(e), setPagina(null), setCargando(false)),
    );
    return () => {
      vigente = false;
    };
  }, [empresaId, consulta]);

  async function cargarMas() {
    if (!pagina?.siguiente) return;
    setMasCargando(true);
    try {
      const p = await api<Pagina>("GET", `/api/empresas/${empresaId}/bitacora?${consulta}&antes=${pagina.siguiente}`);
      setPagina({ entradas: [...pagina.entradas, ...p.entradas], siguiente: p.siguiente });
    } catch (e) {
      setError(e);
    } finally {
      setMasCargando(false);
    }
  }

  async function bajar() {
    setDescargando(true);
    setError(null);
    try {
      await descargar(`/api/empresas/${empresaId}/bitacora.csv?${consulta}`, "bitacora-accesos.csv");
    } catch (e) {
      setError(e instanceof ErrorApi ? e : new ErrorApi(0, "error", String(e)));
    } finally {
      setDescargando(false);
    }
  }

  const cambiar = (campo: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [campo]: e.target.value });

  return (
    <>
      <Encabezado titulo="Bitácora de accesos" sub={s.empresas.find((e) => e.id === empresaId)?.razon_social}>
        <button className="btn sec" onClick={bajar} disabled={descargando || !pagina?.entradas.length}>
          {descargando ? "Descargando…" : "Descargar CSV"}
        </button>
      </Encabezado>
      <div className="aviso">
        Registro de quién vio o cambió datos personales de su empresa: integrantes de comités, asistencia a reuniones y documentos (Ley 21.719).
        Cada entrada guarda la IP y el navegador desde donde se hizo. Solo lo consulta el administrador de la empresa y nadie puede modificarlo desde la aplicación. Las descargas también quedan registradas.
      </div>

      <div className="filtros" role="search" aria-label="Filtros de la bitácora">
        <label className="filtro">
          Desde
          <input type="date" value={f.desde} max={f.hasta || undefined} onChange={cambiar("desde")} />
        </label>
        <label className="filtro">
          Hasta
          <input type="date" value={f.hasta} min={f.desde || undefined} onChange={cambiar("hasta")} />
        </label>
        <label className="filtro">
          Persona
          <select value={f.usuario_id} onChange={cambiar("usuario_id")}>
            <option value="">Todas</option>
            {(actores.datos ?? []).map((a) => (
              <option key={a.id} value={a.id}>{nombreDe(a)}</option>
            ))}
          </select>
        </label>
        <label className="filtro">
          Comité
          <select value={f.comite_id} onChange={cambiar("comite_id")}>
            <option value="">Todos</option>
            {(comites.datos ?? []).map((c) => (
              <option key={c.id} value={c.id}>{c.nombre}</option>
            ))}
          </select>
        </label>
        <label className="filtro">
          Acción
          <select value={f.accion} onChange={cambiar("accion")}>
            <option value="">Todas</option>
            {(Object.keys(ACCION) as Entrada["accion"][]).map((a) => (
              <option key={a} value={a}>{ACCION[a][0]}</option>
            ))}
          </select>
        </label>
      </div>

      <AvisoError error={error} />
      {cargando ? (
        <Cargando />
      ) : pagina ? (
        <div className="tarjeta">
          {pagina.entradas.length === 0 ? (
            <div className="vacio">No hay accesos registrados con estos filtros.</div>
          ) : (
            <div className="tabla">
              <table>
                <thead>
                  <tr><th>Fecha y hora</th><th>Persona</th><th>Acción</th><th>Sobre</th><th>Comité</th><th>Origen</th></tr>
                </thead>
                <tbody>
                  {pagina.entradas.map((e) => (
                    <tr key={e.id}>
                      <td>
                        {formatoFecha(e.fecha)}
                        <div className="sub mono">{e.fecha.slice(11, 16)}</div>
                      </td>
                      <td>
                        <b>{nombreDe(e)}</b>
                        {e.rut && (e.nombres || e.apellidos) ? <div className="sub mono">{formatoRut(e.rut)}</div> : null}
                      </td>
                      <td><Chip tono={ACCION[e.accion][1]}>{ACCION[e.accion][0]}</Chip></td>
                      <td>
                        {ENTIDAD[e.entidad ?? ""] ?? e.entidad ?? "—"}
                        {e.detalle && e.entidad !== "log_acceso" ? <div className="sub">{e.detalle}</div> : null}
                      </td>
                      <td>{e.comite_id ? <Link to={`/comites/${e.comite_id}`}>{e.comite}</Link> : "—"}</td>
                      <td>
                        {e.ip ? <span className="mono">{e.ip}</span> : "—"}
                        {e.navegador ? <div className="sub" title={e.navegador}>{navegadorCorto(e.navegador)}</div> : null}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {pagina.siguiente ? (
            <div className="tb" style={{ textAlign: "center" }}>
              <button className="btn sec" onClick={cargarMas} disabled={masCargando}>
                {masCargando ? "Cargando…" : "Ver más antiguos"}
              </button>
            </div>
          ) : null}
        </div>
      ) : null}
    </>
  );
}
