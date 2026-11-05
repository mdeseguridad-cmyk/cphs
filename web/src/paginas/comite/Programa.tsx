import { useState } from "react";
import { api } from "../../api";
import { AvisoError, Campo, Cargando, Chip, Dialogo, icono } from "../../componentes";
import { useRecarga, useSesion } from "../../sesion";
import { formatoFecha, useDatos } from "../../util";
import type { ComiteDetalle } from "../Comite";
import { nombreComision, type Comision } from "./Comisiones";
import type { Integrante } from "./Integrantes";

interface Actividad {
  id: number;
  titulo: string;
  descripcion: string | null;
  clasificacion: "obligatoria_ley" | "recomendada";
  frecuencia: string | null;
  estado: "planificado" | "en_ejecucion" | "cerrado";
  fecha_planificada: string | null;
  fecha_cierre: string | null;
  comision_id: number | null;
  responsable_integrante_id: number | null;
  atrasada: boolean;
}

interface Plantilla {
  id: number;
  nombre: string;
  seccion: string;
  actividades: number;
}

const COLUMNAS = [
  ["planificado", "Planificado"],
  ["en_ejecucion", "En ejecución"],
  ["cerrado", "Cerrado"],
] as const;
const SIGUIENTE = { planificado: "en_ejecucion", en_ejecucion: "cerrado", cerrado: null } as const;
const FRECUENCIAS = ["mensual", "quincenal", "trimestral", "semestral", "anual", "unica", "segun_evento"];
const NOMBRE_FRECUENCIA: Record<string, string> = {
  quincenal: "Quincenal", mensual: "Mensual", trimestral: "Trimestral", semestral: "Semestral", anual: "Anual", unica: "Única", segun_evento: "Según evento",
};

export function Programa(p: { comite: ComiteDetalle; editable: boolean }) {
  const s = useSesion();
  const [n, recargar] = useRecarga();
  const [nueva, setNueva] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const id = p.comite.id;
  const actividades = useDatos(() => api<Actividad[]>("GET", `/api/comites/${id}/actividades`), [id, n]);
  const comisiones = useDatos(() => api<Comision[]>("GET", `/api/comites/${id}/comisiones`).catch(() => []), [id]);
  const seccion = s.empresas.find((e) => e.id === p.comite.empresa_id)?.seccion ?? null;
  const plantillas = useDatos(
    () => api<Plantilla[]>("GET", `/api/plantillas${seccion ? `?seccion=${seccion}` : ""}`),
    [seccion],
  );
  const comisionPorId = new Map((comisiones.datos ?? []).map((c) => [c.id, c]));

  async function hacer(fn: () => Promise<unknown>) {
    setError(null);
    try {
      await fn();
      recargar();
    } catch (e) {
      setError(e);
    }
  }

  if (actividades.cargando && !actividades.datos) return <Cargando />;
  const lista = actividades.datos ?? [];

  return (
    <>
      <AvisoError error={actividades.error ?? error} />
      {lista.length === 0 ? (
        <div className="tarjeta">
          <div className="th"><h3>Programa de trabajo</h3></div>
          <div className="tb">
            <p style={{ marginTop: 0 }}>El comité aún no tiene programa de trabajo.{p.editable ? " Puede partir desde la plantilla de su rubro y ajustarla." : ""}</p>
            {p.editable ? (
              <div className="filtros">
                {(plantillas.datos ?? []).map((pl) => (
                  <button
                    key={pl.id}
                    className="btn"
                    onClick={() => hacer(() => api("POST", `/api/comites/${id}/programa`, { plantilla_id: pl.id, anio: new Date().getFullYear() }))}
                  >
                    Usar «{pl.nombre}» ({pl.actividades} actividades)
                  </button>
                ))}
                <button className="btn sec" onClick={() => setNueva(true)}>{icono.mas}Actividad propia</button>
              </div>
            ) : null}
          </div>
        </div>
      ) : (
        <>
          <div className="ph" style={{ marginBottom: 12 }}>
            <div className="sub">
              {lista.filter((a) => a.estado === "cerrado").length} de {lista.length} actividades cerradas
              {lista.some((a) => a.atrasada) ? ` · ${lista.filter((a) => a.atrasada).length} atrasadas` : ""}
            </div>
            {p.editable ? <button className="btn chico" onClick={() => setNueva(true)}>{icono.mas}Nueva actividad</button> : null}
          </div>
          <div className="kanban">
            {COLUMNAS.map(([estado, titulo]) => {
              const col = lista.filter((a) => a.estado === estado);
              return (
                <section key={estado} className="columna" aria-label={titulo}>
                  <h4>{titulo} <span>{col.length}</span></h4>
                  {col.map((a) => {
                    const sig = SIGUIENTE[a.estado];
                    const com = a.comision_id ? comisionPorId.get(a.comision_id) : undefined;
                    return (
                      <article key={a.id} className="ficha">
                        <div className="t">{a.titulo}</div>
                        <div className="m">
                          {a.clasificacion === "obligatoria_ley" ? <Chip tono="acento">Obligatoria</Chip> : null}
                          {a.atrasada ? <Chip tono="crit">Atrasada</Chip> : null}
                          {a.frecuencia ? <span>{NOMBRE_FRECUENCIA[a.frecuencia] ?? a.frecuencia}</span> : null}
                          <span>{a.estado === "cerrado" ? `Cerrada ${formatoFecha(a.fecha_cierre)}` : a.fecha_planificada ? `Plazo ${formatoFecha(a.fecha_planificada)}` : ""}</span>
                        </div>
                        {com ? <div className="m">{nombreComision(com)}</div> : null}
                        {p.editable ? (
                          <div className="a">
                            {sig ? (
                              <button className="btn chico" onClick={() => hacer(() => api("PATCH", `/api/actividades/${a.id}`, { estado: sig }))}>
                                {sig === "cerrado" ? "Cerrar" : "Iniciar"}
                              </button>
                            ) : (
                              <button className="btn sec chico" onClick={() => hacer(() => api("PATCH", `/api/actividades/${a.id}`, { estado: "en_ejecucion" }))}>Reabrir</button>
                            )}
                          </div>
                        ) : null}
                      </article>
                    );
                  })}
                </section>
              );
            })}
          </div>
        </>
      )}
      {nueva ? (
        <NuevaActividad
          comiteId={id}
          comisiones={comisiones.datos ?? []}
          onCerrar={() => setNueva(false)}
          onListo={() => {
            setNueva(false);
            recargar();
          }}
        />
      ) : null}
    </>
  );
}

function NuevaActividad(p: { comiteId: number; comisiones: Comision[]; onCerrar(): void; onListo(): void }) {
  const integrantes = useDatos(() => api<Integrante[]>("GET", `/api/comites/${p.comiteId}/integrantes`), [p.comiteId]);
  const [f, setF] = useState({ titulo: "", descripcion: "", clasificacion: "recomendada", frecuencia: "unica", fecha_planificada: "", comision_id: "", responsable_integrante_id: "" });
  const cambiar = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  return (
    <Dialogo
      titulo="Nueva actividad"
      boton="Crear"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        await api("POST", `/api/comites/${p.comiteId}/actividades`, {
          titulo: f.titulo,
          descripcion: f.descripcion || undefined,
          clasificacion: f.clasificacion,
          frecuencia: f.frecuencia,
          fecha_planificada: f.fecha_planificada || undefined,
          comision_id: f.comision_id ? Number(f.comision_id) : undefined,
          responsable_integrante_id: f.responsable_integrante_id ? Number(f.responsable_integrante_id) : undefined,
        });
        p.onListo();
      }}
    >
      <div className="campos">
        <Campo etiqueta="Actividad" id="a-titulo" completo><input id="a-titulo" value={f.titulo} onChange={cambiar("titulo")} required maxLength={200} /></Campo>
        <Campo etiqueta="Descripción" id="a-desc" completo><textarea id="a-desc" rows={3} value={f.descripcion} onChange={cambiar("descripcion")} /></Campo>
        <Campo etiqueta="Clasificación" id="a-clas">
          <select id="a-clas" value={f.clasificacion} onChange={cambiar("clasificacion")}>
            <option value="recomendada">Recomendada</option>
            <option value="obligatoria_ley">Obligatoria por ley</option>
          </select>
        </Campo>
        <Campo etiqueta="Frecuencia" id="a-frec">
          <select id="a-frec" value={f.frecuencia} onChange={cambiar("frecuencia")}>
            {FRECUENCIAS.map((x) => <option key={x} value={x}>{NOMBRE_FRECUENCIA[x]}</option>)}
          </select>
        </Campo>
        <Campo etiqueta="Plazo" id="a-plazo"><input id="a-plazo" type="date" value={f.fecha_planificada} onChange={cambiar("fecha_planificada")} /></Campo>
        <Campo etiqueta="Comisión" id="a-com">
          <select id="a-com" value={f.comision_id} onChange={cambiar("comision_id")}>
            <option value="">Todo el comité</option>
            {p.comisiones.map((c) => <option key={c.id} value={c.id}>{nombreComision(c)}</option>)}
          </select>
        </Campo>
        <Campo etiqueta="Responsable" id="a-resp" completo>
          <select id="a-resp" value={f.responsable_integrante_id} onChange={cambiar("responsable_integrante_id")}>
            <option value="">Sin responsable</option>
            {(integrantes.datos ?? []).filter((i) => i.vigente).map((i) => <option key={i.id} value={i.id}>{i.nombres} {i.apellidos}</option>)}
          </select>
        </Campo>
      </div>
    </Dialogo>
  );
}
