import { useState } from "react";
import { api } from "../../api";
import { AvisoError, Campo, Cargando, Chip, Dialogo, icono } from "../../componentes";
import { useRecarga } from "../../sesion";
import { formatoFecha, formatoRut, hoy, normalizarRut, rutValido, useDatos } from "../../util";
import type { ComiteDetalle } from "../Comite";

export interface Integrante {
  id: number;
  tipo: "titular" | "suplente";
  representacion: "empresa" | "trabajadores";
  cargo: "presidente" | "secretario" | "integrante";
  es_aforado: boolean;
  fecha_fuero: string | null;
  fecha_inicio: string;
  fecha_termino: string | null;
  vigente: boolean;
  rut: string;
  nombres: string;
  apellidos: string;
  email: string | null;
}

const CARGO = { presidente: "Presidente", secretario: "Secretario", integrante: "Integrante" };

export function Integrantes(p: { comite: ComiteDetalle; editable: boolean; onCambio(): void }) {
  const [n, recargar] = useRecarga();
  const [historicos, setHistoricos] = useState(false);
  const [dialogo, setDialogo] = useState<{ tipo: "nuevo" } | { tipo: "termino"; i: Integrante } | { tipo: "cargo"; i: Integrante } | null>(null);
  const { datos, error, cargando } = useDatos(() => api<Integrante[]>("GET", `/api/comites/${p.comite.id}/integrantes`), [p.comite.id, n]);
  const listo = () => {
    setDialogo(null);
    recargar();
    p.onCambio();
  };
  const filas = (datos ?? []).filter((i) => historicos || i.vigente);

  return (
    <div className="tarjeta">
      <div className="th">
        <h3>Integrantes</h3>
        <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
          <label className="casilla"><input type="checkbox" checked={historicos} onChange={(e) => setHistoricos(e.target.checked)} />Ver históricos</label>
          {p.editable ? <button className="btn chico" onClick={() => setDialogo({ tipo: "nuevo" })}>{icono.mas}Agregar</button> : null}
        </div>
      </div>
      <AvisoError error={error} />
      {cargando && !datos ? (
        <Cargando />
      ) : filas.length === 0 ? (
        <div className="vacio">Aún no hay integrantes.</div>
      ) : (
        <div className="tabla">
          <table>
            <thead>
              <tr><th>Persona</th><th>Estamento</th><th>Tipo</th><th>Cargo</th><th>Desde</th><th /></tr>
            </thead>
            <tbody>
              {filas.map((i) => (
                <tr key={i.id}>
                  <td>
                    <b>{i.nombres} {i.apellidos}</b>
                    <div className="sub mono">{formatoRut(i.rut)}</div>
                  </td>
                  <td>{i.representacion === "empresa" ? "Empresa" : "Trabajadores"}</td>
                  <td>{i.tipo === "titular" ? "Titular" : "Suplente"}</td>
                  <td>
                    {CARGO[i.cargo]} {i.es_aforado ? <Chip tono="acento">Aforado</Chip> : null}
                  </td>
                  <td>
                    {formatoFecha(i.fecha_inicio)}
                    {!i.vigente ? <div className="sub">hasta {formatoFecha(i.fecha_termino)}</div> : null}
                  </td>
                  <td className="acciones">
                    {p.editable && i.vigente ? (
                      <>
                        <button className="btn sec chico" onClick={() => setDialogo({ tipo: "cargo", i })}>Cargo</button>{" "}
                        <button className="btn peligro chico" onClick={() => setDialogo({ tipo: "termino", i })}>Término</button>
                      </>
                    ) : !i.vigente ? <Chip>No vigente</Chip> : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {dialogo?.tipo === "nuevo" ? <NuevoIntegrante comiteId={p.comite.id} onCerrar={() => setDialogo(null)} onListo={listo} /> : null}
      {dialogo?.tipo === "termino" ? <Termino i={dialogo.i} onCerrar={() => setDialogo(null)} onListo={listo} /> : null}
      {dialogo?.tipo === "cargo" ? <Cargo i={dialogo.i} onCerrar={() => setDialogo(null)} onListo={listo} /> : null}
    </div>
  );
}

function NuevoIntegrante(p: { comiteId: number; onCerrar(): void; onListo(): void }) {
  const [f, setF] = useState({
    rut: "", nombres: "", apellidos: "", email: "", tipo: "titular", representacion: "trabajadores",
    cargo: "integrante", es_aforado: false, fecha_fuero: "", fecha_inicio: hoy(),
  });
  const cambiar = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const rutMal = f.rut !== "" && !rutValido(f.rut);
  const puedeAforar = f.tipo === "titular" && f.representacion === "trabajadores";
  return (
    <Dialogo
      titulo="Agregar integrante"
      boton="Agregar"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        if (!rutValido(f.rut)) throw new Error("Revise el RUT y su dígito verificador.");
        await api("POST", `/api/comites/${p.comiteId}/integrantes`, {
          rut: normalizarRut(f.rut),
          nombres: f.nombres,
          apellidos: f.apellidos,
          email: f.email || undefined,
          tipo: f.tipo,
          representacion: f.representacion,
          cargo: f.cargo,
          es_aforado: puedeAforar && f.es_aforado,
          fecha_fuero: puedeAforar && f.es_aforado && f.fecha_fuero ? f.fecha_fuero : undefined,
          fecha_inicio: f.fecha_inicio || undefined,
        });
        p.onListo();
      }}
    >
      <div className="campos">
        <Campo etiqueta="RUT" id="i-rut" error={rutMal ? "RUT o dígito verificador no válido" : undefined}>
          <input id="i-rut" value={f.rut} onChange={cambiar("rut")} required placeholder="12.345.678-5" />
        </Campo>
        <Campo etiqueta="Correo" id="i-email" ayuda="Para convocatorias">
          <input id="i-email" type="email" value={f.email} onChange={cambiar("email")} />
        </Campo>
        <Campo etiqueta="Nombres" id="i-nombres"><input id="i-nombres" value={f.nombres} onChange={cambiar("nombres")} required /></Campo>
        <Campo etiqueta="Apellidos" id="i-apellidos"><input id="i-apellidos" value={f.apellidos} onChange={cambiar("apellidos")} required /></Campo>
        <Campo etiqueta="Estamento" id="i-rep">
          <select id="i-rep" value={f.representacion} onChange={cambiar("representacion")}>
            <option value="trabajadores">Representante de los trabajadores</option>
            <option value="empresa">Representante de la empresa</option>
          </select>
        </Campo>
        <Campo etiqueta="Tipo" id="i-tipo">
          <select id="i-tipo" value={f.tipo} onChange={cambiar("tipo")}>
            <option value="titular">Titular</option>
            <option value="suplente">Suplente</option>
          </select>
        </Campo>
        <Campo etiqueta="Cargo" id="i-cargo">
          <select id="i-cargo" value={f.cargo} onChange={cambiar("cargo")}>
            <option value="integrante">Integrante</option>
            <option value="presidente">Presidente</option>
            <option value="secretario">Secretario</option>
          </select>
        </Campo>
        <Campo etiqueta="Desde" id="i-desde"><input id="i-desde" type="date" value={f.fecha_inicio} onChange={cambiar("fecha_inicio")} /></Campo>
        {puedeAforar ? (
          <>
            <div className="campo completo">
              <label className="casilla"><input type="checkbox" checked={f.es_aforado} onChange={(e) => setF({ ...f, es_aforado: e.target.checked })} />Integrante aforado (con fuero)</label>
            </div>
            {f.es_aforado ? (
              <Campo etiqueta="Fecha del fuero" id="i-fuero"><input id="i-fuero" type="date" value={f.fecha_fuero} onChange={cambiar("fecha_fuero")} /></Campo>
            ) : null}
          </>
        ) : null}
      </div>
    </Dialogo>
  );
}

function Termino(p: { i: Integrante; onCerrar(): void; onListo(): void }) {
  const [fecha, setFecha] = useState(hoy());
  return (
    <Dialogo
      titulo={`Término de ${p.i.nombres} ${p.i.apellidos}`}
      boton="Registrar término"
      peligro
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        await api("POST", `/api/integrantes/${p.i.id}/termino`, { fecha_termino: fecha });
        p.onListo();
      }}
    >
      <p style={{ marginTop: 0 }}>La persona deja de integrar el comité; su participación queda en el historial.</p>
      <Campo etiqueta="Fecha de término" id="t-fecha"><input id="t-fecha" type="date" value={fecha} min={p.i.fecha_inicio} onChange={(e) => setFecha(e.target.value)} required /></Campo>
    </Dialogo>
  );
}

function Cargo(p: { i: Integrante; onCerrar(): void; onListo(): void }) {
  const [cargo, setCargo] = useState(p.i.cargo);
  return (
    <Dialogo
      titulo={`Cargo de ${p.i.nombres} ${p.i.apellidos}`}
      boton="Guardar"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        await api("PATCH", `/api/integrantes/${p.i.id}`, { cargo });
        p.onListo();
      }}
    >
      <Campo etiqueta="Cargo" id="g-cargo" ayuda="Cada comité tiene un solo presidente y un solo secretario vigentes.">
        <select id="g-cargo" value={cargo} onChange={(e) => setCargo(e.target.value as Integrante["cargo"])}>
          <option value="integrante">Integrante</option>
          <option value="presidente">Presidente</option>
          <option value="secretario">Secretario</option>
        </select>
      </Campo>
    </Dialogo>
  );
}
