import { useState } from "react";
import { api } from "../../api";
import { AvisoError, Campo, Cargando, Dialogo, icono } from "../../componentes";
import { useRecarga } from "../../sesion";
import { useDatos } from "../../util";
import type { ComiteDetalle } from "../Comite";
import type { Integrante } from "./Integrantes";

export interface Comision {
  id: number;
  tipo: "investigacion_accidentes" | "capacitacion_difusion" | "inspeccion_observacion" | "personalizada";
  nombre: string | null;
  integrantes: number[];
}

export const NOMBRE_COMISION: Record<Comision["tipo"], string> = {
  investigacion_accidentes: "Investigación de accidentes y enfermedades profesionales",
  capacitacion_difusion: "Capacitación y difusión",
  inspeccion_observacion: "Inspección y observación",
  personalizada: "Personalizada",
};

export const nombreComision = (c: Comision) => (c.tipo === "personalizada" ? (c.nombre ?? "Comisión") : NOMBRE_COMISION[c.tipo]);

export function Comisiones(p: { comite: ComiteDetalle; editable: boolean }) {
  const [n, recargar] = useRecarga();
  const [dialogo, setDialogo] = useState<{ tipo: "nueva" } | { tipo: "miembros"; c: Comision } | null>(null);
  const comisiones = useDatos(() => api<Comision[]>("GET", `/api/comites/${p.comite.id}/comisiones`), [p.comite.id, n]);
  const integrantes = useDatos(() => api<Integrante[]>("GET", `/api/comites/${p.comite.id}/integrantes`), [p.comite.id]);
  const porId = new Map((integrantes.datos ?? []).map((i) => [i.id, i]));
  const listo = () => {
    setDialogo(null);
    recargar();
  };

  return (
    <div className="tarjeta">
      <div className="th">
        <h3>Comisiones</h3>
        {p.editable ? <button className="btn chico" onClick={() => setDialogo({ tipo: "nueva" })}>{icono.mas}Nueva comisión</button> : null}
      </div>
      <AvisoError error={comisiones.error} />
      {comisiones.cargando && !comisiones.datos ? (
        <Cargando />
      ) : !comisiones.datos?.length ? (
        <div className="vacio">El comité aún no tiene comisiones. El DS 44 considera investigación de accidentes, capacitación y difusión, e inspección y observación.</div>
      ) : (
        <div className="tabla">
          <table>
            <thead><tr><th>Comisión</th><th>Integrantes</th><th /></tr></thead>
            <tbody>
              {comisiones.datos.map((c) => (
                <tr key={c.id}>
                  <td><b>{nombreComision(c)}</b></td>
                  <td>
                    {c.integrantes.length
                      ? c.integrantes.map((i) => porId.get(i)).filter(Boolean).map((i) => `${i!.nombres} ${i!.apellidos}`).join(", ")
                      : <span className="sub">Sin integrantes</span>}
                  </td>
                  <td className="acciones">
                    {p.editable ? <button className="btn sec chico" onClick={() => setDialogo({ tipo: "miembros", c })}>Integrantes</button> : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {dialogo?.tipo === "nueva" ? (
        <NuevaComision comiteId={p.comite.id} existentes={(comisiones.datos ?? []).map((c) => c.tipo)} onCerrar={() => setDialogo(null)} onListo={listo} />
      ) : null}
      {dialogo?.tipo === "miembros" ? (
        <Miembros c={dialogo.c} integrantes={(integrantes.datos ?? []).filter((i) => i.vigente)} onCerrar={() => setDialogo(null)} onListo={listo} />
      ) : null}
    </div>
  );
}

function NuevaComision(p: { comiteId: number; existentes: Comision["tipo"][]; onCerrar(): void; onListo(): void }) {
  const disponibles = (Object.keys(NOMBRE_COMISION) as Comision["tipo"][]).filter((t) => t === "personalizada" || !p.existentes.includes(t));
  const [tipo, setTipo] = useState<Comision["tipo"]>(disponibles[0] ?? "personalizada");
  const [nombre, setNombre] = useState("");
  return (
    <Dialogo
      titulo="Nueva comisión"
      boton="Crear"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        await api("POST", `/api/comites/${p.comiteId}/comisiones`, { tipo, nombre: tipo === "personalizada" ? nombre : undefined });
        p.onListo();
      }}
    >
      <div className="campos">
        <Campo etiqueta="Tipo" id="co-tipo" completo>
          <select id="co-tipo" value={tipo} onChange={(e) => setTipo(e.target.value as Comision["tipo"])}>
            {disponibles.map((t) => <option key={t} value={t}>{NOMBRE_COMISION[t]}</option>)}
          </select>
        </Campo>
        {tipo === "personalizada" ? (
          <Campo etiqueta="Nombre" id="co-nombre" completo><input id="co-nombre" value={nombre} onChange={(e) => setNombre(e.target.value)} required /></Campo>
        ) : null}
      </div>
    </Dialogo>
  );
}

function Miembros(p: { c: Comision; integrantes: Integrante[]; onCerrar(): void; onListo(): void }) {
  const [sel, setSel] = useState(new Set(p.c.integrantes));
  return (
    <Dialogo
      titulo={nombreComision(p.c)}
      boton="Guardar"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        await api("PUT", `/api/comisiones/${p.c.id}/integrantes`, { integrantes: [...sel] });
        p.onListo();
      }}
    >
      {p.integrantes.length === 0 ? <p>Primero agregue integrantes al comité.</p> : null}
      {p.integrantes.map((i) => (
        <label key={i.id} className="casilla" style={{ padding: "6px 0" }}>
          <input
            type="checkbox"
            checked={sel.has(i.id)}
            onChange={(e) => {
              const n = new Set(sel);
              if (e.target.checked) n.add(i.id);
              else n.delete(i.id);
              setSel(n);
            }}
          />
          {i.nombres} {i.apellidos} <span className="sub">· {i.representacion === "empresa" ? "empresa" : "trabajadores"}</span>
        </label>
      ))}
    </Dialogo>
  );
}
