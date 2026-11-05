import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { api } from "../api";
import { AvisoError, Campo, Cargando, Chip, Dialogo, Encabezado, icono } from "../componentes";
import { useRecarga, useSesion, useTitulo } from "../sesion";
import { formatoFecha, useDatos } from "../util";
import { tonoCumplimiento } from "./Panel";

export interface ComiteFila {
  id: number;
  nombre: string;
  empresa_id: number;
  empresa: string;
  centro: string | null;
  comuna: string | null;
  estado: "activo" | "baja";
  fecha_constitucion: string | null;
  periodo_fin: string | null;
  es_paritario: boolean | null;
  cumplimiento: string | null;
}

export interface Centro {
  id: number;
  nombre: string;
  alias: string | null;
  comuna: string | null;
  comuna_id: number | null;
  direccion_calle: string | null;
  direccion_numero: string | null;
  masa_trabajadores: number | null;
  estado: "vigente" | "no_vigente";
  codigo_externo: string | null;
  comites: number;
}

export function Comites() {
  useTitulo("Comités");
  const s = useSesion();
  const nav = useNavigate();
  const [estado, setEstado] = useState("activo");
  const [nuevo, setNuevo] = useState(false);
  const [n, recargar] = useRecarga();
  const q = new URLSearchParams();
  if (s.empresaId !== null) q.set("empresa_id", String(s.empresaId));
  if (estado) q.set("estado", estado);
  const { datos, error, cargando } = useDatos(() => api<ComiteFila[]>("GET", `/api/comites?${q}`), [q.toString(), n]);

  return (
    <>
      <Encabezado titulo="Comités" sub="Comités paritarios de higiene y seguridad">
        {s.esAdmin(s.empresaId) ? (
          <button className="btn" onClick={() => setNuevo(true)}>{icono.mas}Nuevo comité</button>
        ) : null}
      </Encabezado>
      <div className="filtros">
        <select aria-label="Estado" value={estado} onChange={(e) => setEstado(e.target.value)}>
          <option value="activo">Activos</option>
          <option value="baja">De baja</option>
          <option value="">Todos</option>
        </select>
      </div>
      <AvisoError error={error} />
      {cargando ? (
        <Cargando />
      ) : (
        <div className="tarjeta">
          {!datos?.length ? (
            <div className="vacio">No hay comités {estado === "activo" ? "activos" : estado === "baja" ? "de baja" : ""}.</div>
          ) : (
            <div className="tabla">
              <table>
                <thead>
                  <tr>
                    <th>Comité</th>
                    {s.empresaId === null ? <th>Empresa</th> : null}
                    <th>Centro de trabajo</th>
                    <th>Constitución</th>
                    <th>Cumplimiento</th>
                    <th>Estado</th>
                  </tr>
                </thead>
                <tbody>
                  {datos.map((c) => {
                    const cu = c.cumplimiento === null ? null : Number(c.cumplimiento);
                    return (
                      <tr key={c.id} className="clic" onClick={() => nav(`/comites/${c.id}`)}>
                        <td><b>{c.nombre}</b></td>
                        {s.empresaId === null ? <td>{c.empresa}</td> : null}
                        <td>{c.centro ?? "—"}<div className="sub">{c.comuna ?? ""}</div></td>
                        <td>{formatoFecha(c.fecha_constitucion)}</td>
                        <td>{cu === null ? "—" : <Chip tono={tonoCumplimiento(cu)}>{cu}%</Chip>}</td>
                        <td>{c.estado === "activo" ? <Chip tono="ok">Activo</Chip> : <Chip>De baja</Chip>}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
      {nuevo && s.empresaId !== null ? (
        <NuevoComite
          empresaId={s.empresaId}
          onCerrar={() => setNuevo(false)}
          onCreado={(id) => {
            setNuevo(false);
            recargar();
            nav(`/comites/${id}`);
          }}
        />
      ) : null}
    </>
  );
}

function NuevoComite(p: { empresaId: number; onCerrar(): void; onCreado(id: number): void }) {
  const centros = useDatos(() => api<Centro[]>("GET", `/api/empresas/${p.empresaId}/centros`), [p.empresaId]);
  const [f, setF] = useState({ nombre: "", sucursal_id: "", fecha_constitucion: "", periodo_inicio: "", periodo_fin: "", n_titulares: "3", n_suplentes: "3" });
  const cambiar = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  return (
    <Dialogo
      titulo="Nuevo comité"
      boton="Crear comité"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        const r = await api<{ id: number }>("POST", "/api/comites", {
          empresa_id: p.empresaId,
          nombre: f.nombre,
          sucursal_id: f.sucursal_id ? Number(f.sucursal_id) : undefined,
          fecha_constitucion: f.fecha_constitucion || undefined,
          periodo_inicio: f.periodo_inicio || undefined,
          periodo_fin: f.periodo_fin || undefined,
          n_titulares: Number(f.n_titulares),
          n_suplentes: Number(f.n_suplentes),
        });
        p.onCreado(r.id);
      }}
    >
      <div className="campos">
        <Campo etiqueta="Nombre" id="c-nombre" completo>
          <input id="c-nombre" value={f.nombre} onChange={cambiar("nombre")} required maxLength={180} placeholder="CPHS Planta Norte" />
        </Campo>
        <Campo etiqueta="Centro de trabajo" id="c-centro" completo>
          <select id="c-centro" value={f.sucursal_id} onChange={cambiar("sucursal_id")}>
            <option value="">Sin centro asignado</option>
            {(centros.datos ?? []).filter((c) => c.estado === "vigente").map((c) => (
              <option key={c.id} value={c.id}>{c.alias || c.nombre}{c.comuna ? ` · ${c.comuna}` : ""}</option>
            ))}
          </select>
        </Campo>
        <Campo etiqueta="Fecha de constitución" id="c-const">
          <input id="c-const" type="date" value={f.fecha_constitucion} onChange={cambiar("fecha_constitucion")} />
        </Campo>
        <div />
        <Campo etiqueta="Inicio del periodo" id="c-ini">
          <input id="c-ini" type="date" value={f.periodo_inicio} onChange={cambiar("periodo_inicio")} />
        </Campo>
        <Campo etiqueta="Fin del periodo" id="c-fin" ayuda="El periodo del comité es de dos años.">
          <input id="c-fin" type="date" value={f.periodo_fin} onChange={cambiar("periodo_fin")} />
        </Campo>
        <Campo etiqueta="Titulares por estamento" id="c-tit">
          <input id="c-tit" type="number" min={1} max={10} value={f.n_titulares} onChange={cambiar("n_titulares")} />
        </Campo>
        <Campo etiqueta="Suplentes por estamento" id="c-sup">
          <input id="c-sup" type="number" min={0} max={10} value={f.n_suplentes} onChange={cambiar("n_suplentes")} />
        </Campo>
      </div>
    </Dialogo>
  );
}
