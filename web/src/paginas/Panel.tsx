import { useNavigate } from "react-router-dom";
import { api } from "../api";
import { AvisoError, Cargando, Chip, Encabezado } from "../componentes";
import { useSesion, useTitulo } from "../sesion";
import { useDatos } from "../util";

export interface Indicador {
  comite_id: number;
  comite: string;
  empresa_id: number;
  empresa: string;
  estado: string;
  reuniones_realizadas: number;
  reuniones_exigidas: number;
  realizadas_sin_acta: number;
  cumplimiento: string | null;
  es_paritario: boolean | null;
  actividades_atrasadas: number;
}

export function tonoCumplimiento(v: number | null): "ok" | "warn" | "crit" | undefined {
  if (v === null) return undefined;
  return v >= 90 ? "ok" : v >= 70 ? "warn" : "crit";
}

export function Panel() {
  useTitulo("Panel");
  const s = useSesion();
  const nav = useNavigate();
  const anio = new Date().getFullYear();
  const { datos, error, cargando } = useDatos(() => api<Indicador[]>("GET", `/api/indicadores?anio=${anio}`), [anio]);
  const filas = (datos ?? []).filter((i) => i.estado === "activo" && (s.empresaId === null || i.empresa_id === s.empresaId));
  const conDato = filas.filter((f) => f.cumplimiento !== null);
  const promedio = conDato.length ? Math.round(conDato.reduce((a, f) => a + Number(f.cumplimiento), 0) / conDato.length) : null;
  const noParitarios = filas.filter((f) => f.es_paritario === false).length;
  const atrasadas = filas.reduce((a, f) => a + Number(f.actividades_atrasadas), 0);
  const sinActa = filas.reduce((a, f) => a + Number(f.realizadas_sin_acta), 0);

  return (
    <>
      <Encabezado titulo="Panel" sub={`Cumplimiento del DS 44 · año ${anio}`} />
      <AvisoError error={error} />
      {cargando ? (
        <Cargando />
      ) : (
        <>
          <div className="kpis">
            <div className="kpi"><div className="l">Comités activos</div><div className="v num">{filas.length}</div><div className="s">{s.empresaId === null ? "en todas sus empresas" : "en la empresa"}</div></div>
            <div className="kpi"><div className="l">Cumplimiento de reuniones</div><div className="v num">{promedio === null ? "—" : `${promedio}%`}</div><div className="s">promedio, reuniones exigidas a la fecha</div></div>
            <div className="kpi"><div className="l">Comités no paritarios</div><div className="v num">{s.esOrganismo && s.empresaId === null ? "—" : noParitarios}</div><div className="s">titulares y suplentes incompletos</div></div>
            <div className="kpi"><div className="l">Actividades atrasadas</div><div className="v num">{atrasadas}</div><div className="s">{sinActa ? `${sinActa} reuniones sin acta` : "del programa de trabajo"}</div></div>
          </div>
          <div className="tarjeta">
            <div className="th"><h3>Comités</h3></div>
            {filas.length === 0 ? (
              <div className="vacio">No hay comités activos.</div>
            ) : (
              <div className="tabla">
                <table>
                  <thead>
                    <tr>
                      <th>Comité</th>
                      {s.empresaId === null ? <th>Empresa</th> : null}
                      <th>Reuniones</th>
                      <th>Cumplimiento</th>
                      <th>Paridad</th>
                      <th>Atrasadas</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filas.map((f) => {
                      const c = f.cumplimiento === null ? null : Number(f.cumplimiento);
                      return (
                        <tr key={f.comite_id} className="clic" onClick={() => nav(`/comites/${f.comite_id}`)}>
                          <td><b>{f.comite}</b></td>
                          {s.empresaId === null ? <td>{f.empresa}</td> : null}
                          <td className="num">{f.reuniones_realizadas} de {f.reuniones_exigidas}</td>
                          <td>{c === null ? <Chip>Sin reuniones</Chip> : <Chip tono={tonoCumplimiento(c)}>{c}%</Chip>}</td>
                          <td>{f.es_paritario === null ? "—" : f.es_paritario ? <Chip tono="ok">Paritario</Chip> : <Chip tono="warn">Incompleto</Chip>}</td>
                          <td className="num">{Number(f.actividades_atrasadas) || "—"}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </>
      )}
    </>
  );
}
