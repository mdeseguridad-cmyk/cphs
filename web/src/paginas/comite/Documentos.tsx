import { useState } from "react";
import { api, subirDocumento } from "../../api";
import { AvisoError, Campo, Cargando, Chip, Dialogo, icono } from "../../componentes";
import { useRecarga } from "../../sesion";
import { formatoFecha, formatoTamano, useDatos } from "../../util";
import type { ComiteDetalle } from "../Comite";

export interface DocumentoFila {
  id: number;
  tipo: string;
  nombre: string;
  mime: string | null;
  tamano_bytes: number;
  estado: "pendiente" | "disponible";
  fecha_documento: string | null;
  fecha_carga: string;
  contiene_datos_sensibles: boolean;
}

export const TIPO_DOCUMENTO: Record<string, string> = {
  reunion: "Acta de reunión",
  constitucion: "Acta de constitución",
  disolucion: "Disolución",
  capacitacion: "Capacitación",
  investigacion: "Investigación",
  informe_auditoria: "Informe de auditoría",
  otro: "Otro",
};

const ACEPTADOS = "application/pdf,image/jpeg,image/png,application/vnd.openxmlformats-officedocument.wordprocessingml.document";
const MAX = 25 * 1024 * 1024;

export function Documentos(p: { comite: ComiteDetalle; editable: boolean }) {
  const [n, recargar] = useRecarga();
  const [subir, setSubir] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const { datos, error: errorCarga, cargando } = useDatos(() => api<DocumentoFila[]>("GET", `/api/comites/${p.comite.id}/documentos`), [p.comite.id, n]);

  async function descargar(d: DocumentoFila) {
    setError(null);
    try {
      const r = await api<{ url: string }>("GET", `/api/documentos/${d.id}/descarga`);
      window.location.assign(r.url);
    } catch (e) {
      setError(e);
    }
  }

  return (
    <div className="tarjeta">
      <div className="th">
        <h3>Documentos</h3>
        {p.editable ? <button className="btn chico" onClick={() => setSubir(true)}>{icono.mas}Subir documento</button> : null}
      </div>
      <AvisoError error={errorCarga ?? error} />
      {cargando && !datos ? (
        <Cargando />
      ) : !datos?.length ? (
        <div className="vacio">No hay documentos. Suba aquí el acta de constitución y las actas de cada reunión.</div>
      ) : (
        <div className="tabla">
          <table>
            <thead><tr><th>Documento</th><th>Tipo</th><th>Fecha</th><th>Tamaño</th><th /></tr></thead>
            <tbody>
              {datos.map((d) => (
                <tr key={d.id}>
                  <td>
                    <b>{d.nombre}</b> {d.contiene_datos_sensibles ? <Chip tono="crit">Datos de salud</Chip> : null}
                    <div className="sub">Cargado {formatoFecha(d.fecha_carga)}</div>
                  </td>
                  <td>{TIPO_DOCUMENTO[d.tipo] ?? d.tipo}</td>
                  <td>{formatoFecha(d.fecha_documento)}</td>
                  <td className="num">{formatoTamano(Number(d.tamano_bytes))}</td>
                  <td className="acciones">
                    {d.estado === "disponible" ? (
                      <button className="btn sec chico" onClick={() => descargar(d)}>Descargar</button>
                    ) : (
                      <Chip tono="warn">Carga incompleta</Chip>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {subir ? <Subir comiteId={p.comite.id} onCerrar={() => setSubir(false)} onListo={() => { setSubir(false); recargar(); }} /> : null}
    </div>
  );
}

function Subir(p: { comiteId: number; onCerrar(): void; onListo(): void }) {
  const [archivo, setArchivo] = useState<File | null>(null);
  const [f, setF] = useState({ tipo: "reunion", nombre: "", fecha_documento: "" });
  const cambiar = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  return (
    <Dialogo
      titulo="Subir documento"
      boton="Subir"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        if (!archivo) throw new Error("Elija un archivo.");
        if (archivo.size > MAX) throw new Error("El archivo supera los 25 MB.");
        await subirDocumento(p.comiteId, archivo, {
          tipo: f.tipo,
          nombre: f.nombre || archivo.name.replace(/\.[^.]+$/, ""),
          fecha_documento: f.fecha_documento || undefined,
        });
        p.onListo();
      }}
    >
      <div className="campos">
        <Campo etiqueta="Archivo" id="d-archivo" completo ayuda="PDF, JPG, PNG o Word, hasta 25 MB. Se sube cifrado y se verifica su integridad.">
          <input
            id="d-archivo"
            type="file"
            accept={ACEPTADOS}
            required
            onChange={(e) => {
              const a = e.target.files?.[0] ?? null;
              setArchivo(a);
              if (a && !f.nombre) setF({ ...f, nombre: a.name.replace(/\.[^.]+$/, "") });
            }}
          />
        </Campo>
        <Campo etiqueta="Tipo" id="d-tipo">
          <select id="d-tipo" value={f.tipo} onChange={cambiar("tipo")}>
            {Object.entries(TIPO_DOCUMENTO).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </Campo>
        <Campo etiqueta="Fecha del documento" id="d-fecha"><input id="d-fecha" type="date" value={f.fecha_documento} onChange={cambiar("fecha_documento")} /></Campo>
        <Campo etiqueta="Nombre" id="d-nombre" completo><input id="d-nombre" value={f.nombre} onChange={cambiar("nombre")} maxLength={200} /></Campo>
        {f.tipo === "investigacion" ? <div className="aviso warn campo completo">Las investigaciones contienen datos de salud: solo las ve la empresa y el comité.</div> : null}
      </div>
    </Dialogo>
  );
}
