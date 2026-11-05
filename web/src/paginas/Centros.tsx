import { useState } from "react";
import { api } from "../api";
import { AvisoError, Campo, Cargando, Chip, Dialogo, Encabezado, icono } from "../componentes";
import { useRecarga, useSesion, useTitulo } from "../sesion";
import { useDatos } from "../util";
import type { Centro } from "./Comites";

interface Comuna {
  id: number;
  nombre: string;
  region: string;
}

export function Centros() {
  useTitulo("Centros de trabajo");
  const s = useSesion();
  const empresaId = s.empresaId!;
  const admin = s.esAdmin(empresaId);
  const [n, recargar] = useRecarga();
  const [dialogo, setDialogo] = useState<{ tipo: "nuevo" } | { tipo: "editar"; c: Centro } | null>(null);
  const { datos, error, cargando } = useDatos(() => api<Centro[]>("GET", `/api/empresas/${empresaId}/centros`), [empresaId, n]);
  const empresa = s.empresas.find((e) => e.id === empresaId);
  const sincronizados = (datos ?? []).some((c) => c.codigo_externo);
  const listo = () => {
    setDialogo(null);
    recargar();
  };

  return (
    <>
      <Encabezado titulo="Centros de trabajo" sub={empresa?.razon_social}>
        {admin ? <button className="btn" onClick={() => setDialogo({ tipo: "nuevo" })}>{icono.mas}Agregar centro</button> : null}
      </Encabezado>
      {sincronizados ? (
        <div className="aviso">Los centros con código se actualizan cada día desde el sistema de su organismo{empresa?.codigo_contrato ? ` (contrato ${empresa.codigo_contrato})` : ""}. Los que agregue aquí no se tocan.</div>
      ) : null}
      <AvisoError error={error} />
      {cargando && !datos ? (
        <Cargando />
      ) : (
        <div className="tarjeta">
          {!datos?.length ? (
            <div className="vacio">La empresa aún no tiene centros de trabajo.</div>
          ) : (
            <div className="tabla">
              <table>
                <thead><tr><th>Centro</th><th>Código</th><th>Comuna</th><th>Trabajadores</th><th>Comités</th><th>Estado</th><th /></tr></thead>
                <tbody>
                  {datos.map((c) => (
                    <tr key={c.id}>
                      <td><b>{c.alias || c.nombre}</b>{c.alias ? <div className="sub">{c.nombre}</div> : null}</td>
                      <td className="mono">{c.codigo_externo ?? "—"}</td>
                      <td>{c.comuna ?? "—"}</td>
                      <td className="num">{c.masa_trabajadores ?? "—"}</td>
                      <td className="num">{c.comites}</td>
                      <td>{c.estado === "vigente" ? <Chip tono="ok">Vigente</Chip> : <Chip>No vigente</Chip>}</td>
                      <td className="acciones">{admin ? <button className="btn sec chico" onClick={() => setDialogo({ tipo: "editar", c })}>Editar</button> : null}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
      {dialogo ? (
        <FormCentro empresaId={empresaId} c={dialogo.tipo === "editar" ? dialogo.c : null} onCerrar={() => setDialogo(null)} onListo={listo} />
      ) : null}
    </>
  );
}

function FormCentro(p: { empresaId: number; c: Centro | null; onCerrar(): void; onListo(): void }) {
  const comunas = useDatos(() => api<Comuna[]>("GET", "/api/catalogos/comunas"), []);
  const c = p.c;
  const soloAlias = !!c?.codigo_externo;
  const [f, setF] = useState({
    nombre: c?.nombre ?? "",
    alias: c?.alias ?? "",
    direccion_calle: c?.direccion_calle ?? "",
    direccion_numero: c?.direccion_numero ?? "",
    comuna_id: c?.comuna_id ? String(c.comuna_id) : "",
    masa_trabajadores: c?.masa_trabajadores != null ? String(c.masa_trabajadores) : "",
    estado: c?.estado ?? "vigente",
  });
  const cambiar = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const regiones = [...new Set((comunas.datos ?? []).map((x) => x.region))];
  return (
    <Dialogo
      titulo={c ? "Editar centro" : "Agregar centro"}
      boton="Guardar"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        if (soloAlias) {
          await api("PATCH", `/api/centros/${c!.id}`, { alias: f.alias });
        } else {
          const cuerpo = {
            nombre: f.nombre,
            alias: f.alias || undefined,
            direccion_calle: f.direccion_calle || undefined,
            direccion_numero: f.direccion_numero || undefined,
            comuna_id: f.comuna_id ? Number(f.comuna_id) : undefined,
            masa_trabajadores: f.masa_trabajadores ? Number(f.masa_trabajadores) : undefined,
          };
          if (c) await api("PATCH", `/api/centros/${c.id}`, { ...cuerpo, estado: f.estado });
          else await api("POST", `/api/empresas/${p.empresaId}/centros`, cuerpo);
        }
        p.onListo();
      }}
    >
      {soloAlias ? <div className="aviso">Este centro se actualiza desde el sistema de su organismo: aquí solo puede cambiar su alias.</div> : null}
      <div className="campos">
        <Campo etiqueta="Nombre" id="ce-nombre" completo><input id="ce-nombre" value={f.nombre} onChange={cambiar("nombre")} required disabled={soloAlias} /></Campo>
        <Campo etiqueta="Alias" id="ce-alias" completo ayuda="Nombre corto con que lo conocen en la empresa"><input id="ce-alias" value={f.alias} onChange={cambiar("alias")} /></Campo>
        {!soloAlias ? (
          <>
            <Campo etiqueta="Calle" id="ce-calle"><input id="ce-calle" value={f.direccion_calle} onChange={cambiar("direccion_calle")} /></Campo>
            <Campo etiqueta="Número" id="ce-num"><input id="ce-num" value={f.direccion_numero} onChange={cambiar("direccion_numero")} /></Campo>
            <Campo etiqueta="Comuna" id="ce-comuna">
              <select id="ce-comuna" value={f.comuna_id} onChange={cambiar("comuna_id")}>
                <option value="">Elija una comuna</option>
                {regiones.map((r) => (
                  <optgroup key={r} label={r}>
                    {(comunas.datos ?? []).filter((x) => x.region === r).map((x) => <option key={x.id} value={x.id}>{x.nombre}</option>)}
                  </optgroup>
                ))}
              </select>
            </Campo>
            <Campo etiqueta="Trabajadores" id="ce-masa"><input id="ce-masa" type="number" min={0} value={f.masa_trabajadores} onChange={cambiar("masa_trabajadores")} /></Campo>
            {c ? (
              <Campo etiqueta="Estado" id="ce-estado">
                <select id="ce-estado" value={f.estado} onChange={cambiar("estado")}>
                  <option value="vigente">Vigente</option>
                  <option value="no_vigente">No vigente</option>
                </select>
              </Campo>
            ) : null}
          </>
        ) : null}
      </div>
    </Dialogo>
  );
}
