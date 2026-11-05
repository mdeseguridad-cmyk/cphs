import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { api } from "../api";
import { AvisoError, Campo, Cargando, Chip, Dialogo, Encabezado } from "../componentes";
import { useRecarga, useSesion, useTitulo } from "../sesion";
import { formatoFecha, hoy, useDatos } from "../util";
import { tonoCumplimiento } from "./Panel";
import { Integrantes } from "./comite/Integrantes";
import { Comisiones } from "./comite/Comisiones";
import { Programa } from "./comite/Programa";
import { Reuniones } from "./comite/Reuniones";
import { Documentos } from "./comite/Documentos";

export interface ComiteDetalle {
  id: number;
  nombre: string;
  empresa_id: number;
  empresa: string;
  sucursal_id: number | null;
  centro: string | null;
  comuna: string | null;
  estado: "activo" | "baja";
  fecha_constitucion: string | null;
  fecha_disolucion: string | null;
  periodo_inicio: string | null;
  periodo_fin: string | null;
  n_titulares: number;
  n_suplentes: number;
  paridad: {
    titulares_empresa: number;
    titulares_trabajadores: number;
    suplentes_empresa: number;
    suplentes_trabajadores: number;
    es_paritario: boolean;
  } | null;
  cumplimiento: { anio: number; realizadas: number; no_realizadas: number; exigidas: number; realizadas_sin_acta: number; porcentaje: string | null }[];
}

const PESTANAS = [
  ["resumen", "Resumen"],
  ["integrantes", "Integrantes"],
  ["comisiones", "Comisiones"],
  ["programa", "Programa de trabajo"],
  ["reuniones", "Reuniones"],
  ["documentos", "Documentos"],
] as const;

export function Comite() {
  const id = Number(useParams().id);
  const s = useSesion();
  const nav = useNavigate();
  const [pestana, setPestana] = useState<(typeof PESTANAS)[number][0]>("resumen");
  const [dialogo, setDialogo] = useState<"editar" | "baja" | null>(null);
  const [n, recargar] = useRecarga();
  const { datos: c, error, cargando } = useDatos(() => api<ComiteDetalle>("GET", `/api/comites/${id}`), [id, n]);
  useTitulo(c?.nombre ?? "Comité");

  if (cargando && !c) return <Cargando />;
  if (error || !c) {
    return (
      <>
        <AvisoError error={error} />
        <Link to="/comites">Volver a comités</Link>
      </>
    );
  }
  const editable = s.puedeEditarComite(c);
  const admin = s.esAdmin(c.empresa_id);
  const anual = c.cumplimiento[0];
  const porcentaje = anual?.porcentaje == null ? null : Number(anual.porcentaje);
  // Sin acceso a personas (organismo), la paridad no se puede calcular.
  const veIntegrantes = !s.esOrganismo || s.yo.roles.some((r) => r.empresa_id === c.empresa_id);

  return (
    <>
      <Encabezado
        titulo={c.nombre}
        sub={
          <>
            {c.empresa}
            {c.centro ? ` · ${c.centro}` : ""}
            {c.comuna ? `, ${c.comuna}` : ""}
          </>
        }
      >
        {c.estado === "baja" ? <Chip>De baja desde {formatoFecha(c.fecha_disolucion)}</Chip> : null}
        {veIntegrantes && c.paridad ? (c.paridad.es_paritario ? <Chip tono="ok">Paritario</Chip> : <Chip tono="warn">Paridad incompleta</Chip>) : null}
        {porcentaje !== null ? <Chip tono={tonoCumplimiento(porcentaje)}>Cumplimiento {anual!.anio}: {porcentaje}%</Chip> : null}
        {editable ? <button className="btn sec chico" onClick={() => setDialogo("editar")}>Editar</button> : null}
        {admin && c.estado === "activo" ? <button className="btn peligro chico" onClick={() => setDialogo("baja")}>Dar de baja</button> : null}
      </Encabezado>

      <div className="pestanas" role="tablist">
        {PESTANAS.filter(([k]) => veIntegrantes || !["integrantes", "comisiones", "documentos"].includes(k)).map(([k, t]) => (
          <button key={k} role="tab" aria-selected={pestana === k} className={pestana === k ? "activa" : ""} onClick={() => setPestana(k)}>
            {t}
          </button>
        ))}
      </div>

      {pestana === "resumen" ? <Resumen c={c} veIntegrantes={veIntegrantes} /> : null}
      {pestana === "integrantes" ? <Integrantes comite={c} editable={editable} onCambio={recargar} /> : null}
      {pestana === "comisiones" ? <Comisiones comite={c} editable={editable} /> : null}
      {pestana === "programa" ? <Programa comite={c} editable={editable} /> : null}
      {pestana === "reuniones" ? <Reuniones comite={c} editable={editable} onCambio={recargar} /> : null}
      {pestana === "documentos" ? <Documentos comite={c} editable={editable} /> : null}

      {dialogo === "editar" ? <EditarComite c={c} onCerrar={() => setDialogo(null)} onListo={() => { setDialogo(null); recargar(); }} /> : null}
      {dialogo === "baja" ? (
        <BajaComite c={c} onCerrar={() => setDialogo(null)} onListo={() => { setDialogo(null); nav("/comites"); }} />
      ) : null}
    </>
  );
}

function Resumen(p: { c: ComiteDetalle; veIntegrantes: boolean }) {
  const { c } = p;
  const pa = c.paridad;
  const celda = (v: number, req: number) => <Chip tono={v === req ? "ok" : "warn"}>{v} de {req}</Chip>;
  return (
    <div className="cuadricula">
      <div className="tarjeta">
        <div className="th"><h3>Datos del comité</h3></div>
        <div className="tb">
          <dl className="datos">
            <dt>Empresa</dt><dd>{c.empresa}</dd>
            <dt>Centro de trabajo</dt><dd>{c.centro ?? "—"}</dd>
            <dt>Constitución</dt><dd>{formatoFecha(c.fecha_constitucion)}</dd>
            <dt>Periodo</dt><dd>{c.periodo_inicio ? `${formatoFecha(c.periodo_inicio)} al ${formatoFecha(c.periodo_fin)}` : "—"}</dd>
            <dt>Composición</dt><dd>{c.n_titulares} titulares y {c.n_suplentes} suplentes por estamento</dd>
          </dl>
        </div>
      </div>
      {p.veIntegrantes && pa ? (
        <div className="tarjeta">
          <div className="th"><h3>Paridad</h3>{pa.es_paritario ? <Chip tono="ok">Completa</Chip> : <Chip tono="warn">Incompleta</Chip>}</div>
          <div className="tabla">
            <table>
              <thead><tr><th>Estamento</th><th>Titulares</th><th>Suplentes</th></tr></thead>
              <tbody>
                <tr><td>Empresa</td><td>{celda(pa.titulares_empresa, c.n_titulares)}</td><td>{celda(pa.suplentes_empresa, c.n_suplentes)}</td></tr>
                <tr><td>Trabajadores</td><td>{celda(pa.titulares_trabajadores, c.n_titulares)}</td><td>{celda(pa.suplentes_trabajadores, c.n_suplentes)}</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      ) : null}
      <div className="tarjeta">
        <div className="th"><h3>Cumplimiento de reuniones</h3></div>
        {c.cumplimiento.length === 0 ? (
          <div className="vacio">Aún no hay reuniones registradas.</div>
        ) : (
          <div className="tabla">
            <table>
              <thead><tr><th>Año</th><th>Realizadas</th><th>No realizadas</th><th>Sin acta</th><th>Cumplimiento</th></tr></thead>
              <tbody>
                {c.cumplimiento.map((a) => {
                  const v = a.porcentaje == null ? null : Number(a.porcentaje);
                  return (
                    <tr key={a.anio}>
                      <td>{a.anio}</td>
                      <td className="num">{a.realizadas}</td>
                      <td className="num">{a.no_realizadas}</td>
                      <td className="num">{a.realizadas_sin_acta}</td>
                      <td>{v === null ? "—" : <Chip tono={tonoCumplimiento(v)}>{v}%</Chip>}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}

function EditarComite(p: { c: ComiteDetalle; onCerrar(): void; onListo(): void }) {
  const { c } = p;
  const [f, setF] = useState({
    nombre: c.nombre,
    fecha_constitucion: c.fecha_constitucion ?? "",
    periodo_inicio: c.periodo_inicio ?? "",
    periodo_fin: c.periodo_fin ?? "",
  });
  const cambiar = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  return (
    <Dialogo
      titulo="Editar comité"
      boton="Guardar"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        await api("PATCH", `/api/comites/${c.id}`, {
          nombre: f.nombre,
          fecha_constitucion: f.fecha_constitucion || undefined,
          periodo_inicio: f.periodo_inicio || undefined,
          periodo_fin: f.periodo_fin || undefined,
        });
        p.onListo();
      }}
    >
      <div className="campos">
        <Campo etiqueta="Nombre" id="e-nombre" completo><input id="e-nombre" value={f.nombre} onChange={cambiar("nombre")} required /></Campo>
        <Campo etiqueta="Constitución" id="e-const"><input id="e-const" type="date" value={f.fecha_constitucion} onChange={cambiar("fecha_constitucion")} /></Campo>
        <div />
        <Campo etiqueta="Inicio del periodo" id="e-ini"><input id="e-ini" type="date" value={f.periodo_inicio} onChange={cambiar("periodo_inicio")} /></Campo>
        <Campo etiqueta="Fin del periodo" id="e-fin"><input id="e-fin" type="date" value={f.periodo_fin} onChange={cambiar("periodo_fin")} /></Campo>
      </div>
    </Dialogo>
  );
}

function BajaComite(p: { c: ComiteDetalle; onCerrar(): void; onListo(): void }) {
  const [fecha, setFecha] = useState(hoy());
  return (
    <Dialogo
      titulo="Dar de baja el comité"
      boton="Dar de baja"
      peligro
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        await api("POST", `/api/comites/${p.c.id}/baja`, { fecha_disolucion: fecha });
        p.onListo();
      }}
    >
      <p style={{ marginTop: 0 }}>El comité no se borra: queda de baja con su historial de integrantes, reuniones y actas.</p>
      <Campo etiqueta="Fecha de disolución" id="b-fecha"><input id="b-fecha" type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} required /></Campo>
    </Dialogo>
  );
}
