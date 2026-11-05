import { useState } from "react";
import { api } from "../../api";
import { AvisoError, Campo, Cargando, Chip, Dialogo, icono } from "../../componentes";
import { useRecarga } from "../../sesion";
import { NOMBRES_MES, formatoFecha, hoy, useDatos } from "../../util";
import type { ComiteDetalle } from "../Comite";
import type { DocumentoFila } from "./Documentos";

interface Reunion {
  id: number;
  anio: number;
  mes: number;
  numero: number;
  estado: "planificada" | "realizada" | "no_realizada";
  fecha_programada: string | null;
  fecha_realizada: string | null;
  observacion: string | null;
  acta_documento_id: number | null;
  acta: string | null;
  presentes: number;
}

interface Asistente {
  integrante_id: number;
  nombres: string;
  apellidos: string;
  representacion: string;
  tipo: string;
  presente: boolean | null;
  justificacion: string | null;
}

const ESTADO = { planificada: ["Planificada", undefined], realizada: ["Realizada", "ok"], no_realizada: ["No realizada", "crit"] } as const;

/** Mes ya terminado sin registrar: cuenta como incumplida en el cumplimiento. */
function vencida(r: Reunion): boolean {
  if (r.estado !== "planificada") return false;
  const fin = new Date(r.anio, r.mes, 1);
  return fin <= new Date();
}

export function Reuniones(p: { comite: ComiteDetalle; editable: boolean; onCambio(): void }) {
  const actual = new Date().getFullYear();
  const [anio, setAnio] = useState(actual);
  const [n, recargar] = useRecarga();
  const [error, setError] = useState<unknown>(null);
  const [dialogo, setDialogo] = useState<{ tipo: "registrar" | "asistencia"; r: Reunion } | { tipo: "extra" } | null>(null);
  const id = p.comite.id;
  const { datos, error: errorCarga, cargando } = useDatos(() => api<Reunion[]>("GET", `/api/comites/${id}/reuniones?anio=${anio}`), [id, anio, n]);
  const lista = datos ?? [];
  const listo = () => {
    setDialogo(null);
    recargar();
    p.onCambio();
  };
  async function cronograma() {
    setError(null);
    try {
      await api("POST", `/api/comites/${id}/cronograma`, { anio });
      listo();
    } catch (e) {
      setError(e);
    }
  }
  const porMes = (m: number) => lista.filter((r) => r.mes === m);
  const mesesSinReunion = 12 - new Set(lista.map((r) => r.mes)).size;

  return (
    <>
      <AvisoError error={errorCarga ?? error} />
      <div className="tarjeta">
        <div className="th">
          <h3>Reuniones</h3>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            <select aria-label="Año" value={anio} onChange={(e) => setAnio(Number(e.target.value))}>
              {[actual + 1, actual, actual - 1, actual - 2].map((a) => <option key={a} value={a}>{a}</option>)}
            </select>
            {p.editable && mesesSinReunion > 0 ? <button className="btn chico" onClick={cronograma}>Crear cronograma {anio}</button> : null}
            {p.editable ? <button className="btn sec chico" onClick={() => setDialogo({ tipo: "extra" })}>{icono.mas}Reunión</button> : null}
          </div>
        </div>
        <div className="tb">
          <div className="meses" aria-label={`Cronograma ${anio}`}>
            {NOMBRES_MES.map((m, i) => {
              const rs = porMes(i + 1);
              const estado = rs.some((r) => r.estado === "realizada") ? "realizada" : rs.some((r) => r.estado === "no_realizada" || vencida(r)) ? "no_realizada" : rs.length ? "planificada" : "";
              const texto = estado === "no_realizada" && !rs.some((r) => r.estado === "no_realizada") ? "sin registrar" : estado ? ESTADO[estado][0] : "sin reunión";
              return <div key={m} className={`mes ${estado}`} title={`${m}: ${texto}`}>{m.slice(0, 3)}</div>;
            })}
          </div>
          <p className="sub" style={{ margin: "8px 0 0" }}>El DS 44 exige al menos una reunión ordinaria al mes, con acta. Un mes terminado sin registrar cuenta como incumplido.</p>
        </div>
        {cargando && !datos ? (
          <Cargando />
        ) : lista.length === 0 ? (
          <div className="vacio">No hay reuniones en {anio}.</div>
        ) : (
          <div className="tabla">
            <table>
              <thead><tr><th>N°</th><th>Mes</th><th>Estado</th><th>Fecha</th><th>Acta</th><th>Asistentes</th><th /></tr></thead>
              <tbody>
                {lista.map((r) => (
                  <tr key={r.id}>
                    <td className="num">{r.numero}</td>
                    <td>{NOMBRES_MES[r.mes - 1]}</td>
                    <td>{vencida(r) ? <Chip tono="warn">Sin registrar</Chip> : <Chip tono={ESTADO[r.estado][1]}>{ESTADO[r.estado][0]}</Chip>}</td>
                    <td>{formatoFecha(r.fecha_realizada ?? r.fecha_programada)}</td>
                    <td>{r.acta ?? (r.estado === "realizada" ? <Chip tono="warn">Sin acta</Chip> : "—")}</td>
                    <td className="num">{r.estado === "realizada" ? r.presentes : "—"}</td>
                    <td className="acciones">
                      {p.editable ? (
                        <>
                          <button className="btn sec chico" onClick={() => setDialogo({ tipo: "registrar", r })}>Registrar</button>{" "}
                          {r.estado === "realizada" ? <button className="btn sec chico" onClick={() => setDialogo({ tipo: "asistencia", r })}>Asistencia</button> : null}
                        </>
                      ) : null}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
      {dialogo?.tipo === "registrar" ? <Registrar comiteId={id} r={dialogo.r} onCerrar={() => setDialogo(null)} onListo={listo} /> : null}
      {dialogo?.tipo === "asistencia" ? <Asistencia r={dialogo.r} onCerrar={() => setDialogo(null)} onListo={listo} /> : null}
      {dialogo?.tipo === "extra" ? <NuevaReunion comiteId={id} anio={anio} onCerrar={() => setDialogo(null)} onListo={listo} /> : null}
    </>
  );
}

/** Fecha programada, o hoy si cae en el mes de la reunión, o el día 15 de ese mes. */
function fechaSugerida(r: Reunion): string {
  if (r.fecha_programada) return r.fecha_programada;
  const h = hoy();
  const mes = `${r.anio}-${String(r.mes).padStart(2, "0")}`;
  return h.startsWith(mes) ? h : `${mes}-15`;
}

function Registrar(p: { comiteId: number; r: Reunion; onCerrar(): void; onListo(): void }) {
  const docs = useDatos(() => api<DocumentoFila[]>("GET", `/api/comites/${p.comiteId}/documentos`), [p.comiteId]);
  const actas = (docs.datos ?? []).filter((d) => d.estado === "disponible" && (d.tipo === "reunion" || d.tipo === "constitucion"));
  const [f, setF] = useState({
    estado: p.r.estado === "planificada" ? "realizada" : p.r.estado,
    fecha_realizada: p.r.fecha_realizada ?? fechaSugerida(p.r),
    observacion: p.r.observacion ?? "",
    acta_documento_id: p.r.acta_documento_id ? String(p.r.acta_documento_id) : "",
  });
  const cambiar = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  return (
    <Dialogo
      titulo={`Reunión de ${NOMBRES_MES[p.r.mes - 1]!.toLowerCase()} ${p.r.anio}`}
      boton="Guardar"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        await api("PATCH", `/api/reuniones/${p.r.id}`, {
          estado: f.estado,
          fecha_realizada: f.estado === "realizada" ? f.fecha_realizada : null,
          observacion: f.observacion || null,
          acta_documento_id: f.estado === "realizada" && f.acta_documento_id ? Number(f.acta_documento_id) : null,
        });
        p.onListo();
      }}
    >
      <div className="campos">
        <Campo etiqueta="Estado" id="r-estado">
          <select id="r-estado" value={f.estado} onChange={cambiar("estado")}>
            <option value="realizada">Realizada</option>
            <option value="no_realizada">No realizada</option>
            <option value="planificada">Planificada</option>
          </select>
        </Campo>
        {f.estado === "realizada" ? (
          <>
            <Campo etiqueta="Fecha" id="r-fecha"><input id="r-fecha" type="date" value={f.fecha_realizada} onChange={cambiar("fecha_realizada")} required /></Campo>
            <Campo etiqueta="Acta" id="r-acta" completo ayuda={actas.length ? undefined : "Suba el acta en la pestaña Documentos (tipo reunión) y vuelva a registrarla aquí."}>
              <select id="r-acta" value={f.acta_documento_id} onChange={cambiar("acta_documento_id")}>
                <option value="">Sin acta por ahora</option>
                {actas.map((d) => <option key={d.id} value={d.id}>{d.nombre}</option>)}
              </select>
            </Campo>
          </>
        ) : null}
        <Campo etiqueta="Observación" id="r-obs" completo ayuda={f.estado === "no_realizada" ? "Indique el motivo." : undefined}>
          <textarea id="r-obs" rows={3} value={f.observacion} onChange={cambiar("observacion")} />
        </Campo>
      </div>
    </Dialogo>
  );
}

function Asistencia(p: { r: Reunion; onCerrar(): void; onListo(): void }) {
  const { datos, cargando } = useDatos(() => api<Asistente[]>("GET", `/api/reuniones/${p.r.id}/asistencia`), [p.r.id]);
  const [marcas, setMarcas] = useState<Record<number, { presente: boolean; justificacion: string }>>({});
  const valor = (a: Asistente) => marcas[a.integrante_id] ?? { presente: a.presente ?? true, justificacion: a.justificacion ?? "" };
  return (
    <Dialogo
      titulo="Asistencia"
      boton="Guardar asistencia"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        await api("PUT", `/api/reuniones/${p.r.id}/asistencia`, {
          asistencia: (datos ?? []).map((a) => ({ integrante_id: a.integrante_id, presente: valor(a).presente, justificacion: valor(a).justificacion || undefined })),
        });
        p.onListo();
      }}
    >
      {cargando ? <Cargando /> : null}
      {(datos ?? []).map((a) => {
        const v = valor(a);
        return (
          <div key={a.integrante_id} style={{ padding: "6px 0", borderBottom: "1px solid var(--border)" }}>
            <label className="casilla">
              <input type="checkbox" checked={v.presente} onChange={(e) => setMarcas({ ...marcas, [a.integrante_id]: { ...v, presente: e.target.checked } })} />
              {a.nombres} {a.apellidos} <span className="sub">· {a.tipo}, {a.representacion}</span>
            </label>
            {!v.presente ? (
              <input
                aria-label={`Justificación de ${a.nombres}`}
                placeholder="Justificación (opcional)"
                style={{ width: "100%", marginTop: 6 }}
                value={v.justificacion}
                onChange={(e) => setMarcas({ ...marcas, [a.integrante_id]: { ...v, justificacion: e.target.value } })}
              />
            ) : null}
          </div>
        );
      })}
    </Dialogo>
  );
}

function NuevaReunion(p: { comiteId: number; anio: number; onCerrar(): void; onListo(): void }) {
  const [mes, setMes] = useState(String(new Date().getMonth() + 1));
  const [fecha, setFecha] = useState("");
  return (
    <Dialogo
      titulo="Nueva reunión"
      boton="Crear"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        await api("POST", `/api/comites/${p.comiteId}/reuniones`, { anio: p.anio, mes: Number(mes), fecha_programada: fecha || undefined });
        p.onListo();
      }}
    >
      <div className="campos">
        <Campo etiqueta="Mes" id="n-mes">
          <select id="n-mes" value={mes} onChange={(e) => setMes(e.target.value)}>
            {NOMBRES_MES.map((m, i) => <option key={m} value={i + 1}>{m}</option>)}
          </select>
        </Campo>
        <Campo etiqueta="Fecha programada" id="n-fecha"><input id="n-fecha" type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} /></Campo>
      </div>
    </Dialogo>
  );
}
