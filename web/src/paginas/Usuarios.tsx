import { useState } from "react";
import { api } from "../api";
import { AvisoError, Campo, Cargando, Chip, Dialogo, Encabezado, icono } from "../componentes";
import { NOMBRE_ROL, useRecarga, useSesion, useTitulo, type Acceso } from "../sesion";
import { formatoFecha, formatoRut, normalizarRut, rutValido, useDatos } from "../util";
import type { ComiteFila } from "./Comites";

interface UsuarioFila {
  id: number;
  rut: string;
  estado: "invitado" | "activo" | "bloqueado";
  mfa_habilitado: boolean;
  ultimo_acceso: string | null;
  nombres: string | null;
  apellidos: string | null;
  email: string | null;
  accesos: { acceso_id: number; rol: Acceso["rol"]; comite_id: number | null; comite: string | null; origen: "manual" | "solicitud" | "sso" }[];
}

const ESTADO = { invitado: ["Invitación enviada", "warn"], activo: ["Activo", "ok"], bloqueado: ["Bloqueado", "crit"] } as const;

export function Usuarios() {
  useTitulo("Usuarios y accesos");
  const s = useSesion();
  const empresaId = s.empresaId!;
  const [n, recargar] = useRecarga();
  const [invitar, setInvitar] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const { datos, error: errorCarga, cargando } = useDatos(() => api<UsuarioFila[]>("GET", `/api/empresas/${empresaId}/usuarios`), [empresaId, n]);

  async function accion(fn: () => Promise<unknown>, mensaje: string) {
    setError(null);
    setAviso(null);
    try {
      await fn();
      setAviso(mensaje);
      recargar();
    } catch (e) {
      setError(e);
    }
  }

  return (
    <>
      <Encabezado titulo="Usuarios y accesos" sub={s.empresas.find((e) => e.id === empresaId)?.razon_social}>
        <button className="btn" onClick={() => setInvitar(true)}>{icono.mas}Invitar usuario</button>
      </Encabezado>
      <div className="aviso">
        Paritario no guarda contraseñas. Al invitar, la persona recibe un correo con una clave temporal, define la suya en el primer ingreso y entra con su RUT. Los accesos de origen SSO los entrega el sistema de su organismo en cada ingreso.
      </div>
      {aviso ? <div className="aviso" role="status">{aviso}</div> : null}
      <AvisoError error={errorCarga ?? error} />
      {cargando && !datos ? (
        <Cargando />
      ) : (
        <div className="tarjeta">
          <div className="tabla">
            <table>
              <thead><tr><th>Persona</th><th>Accesos</th><th>Estado</th><th>Último ingreso</th><th /></tr></thead>
              <tbody>
                {(datos ?? []).map((u) => {
                  const propio = u.id === s.yo.id;
                  return (
                    <tr key={u.id}>
                      <td>
                        <b>{[u.nombres, u.apellidos].filter(Boolean).join(" ") || "—"}</b>
                        <div className="sub mono">{formatoRut(u.rut)}</div>
                      </td>
                      <td>
                        {u.accesos.map((a) => (
                          <div key={a.acceso_id} style={{ display: "flex", gap: 6, alignItems: "center", flexWrap: "wrap", marginBottom: 2 }}>
                            {NOMBRE_ROL[a.rol]}{a.comite ? ` · ${a.comite}` : ""}
                            {a.origen === "sso" ? <Chip tono="acento">SSO</Chip> : null}
                            {a.origen !== "sso" && !propio ? (
                              <button
                                className="enlace"
                                aria-label={`Quitar acceso de ${NOMBRE_ROL[a.rol]}`}
                                onClick={() => confirm("¿Quitar este acceso? La persona deja de ver la empresa con ese rol.") && accion(() => api("DELETE", `/api/accesos/${a.acceso_id}`), "Acceso quitado.")}
                              >
                                quitar
                              </button>
                            ) : null}
                          </div>
                        ))}
                      </td>
                      <td><Chip tono={ESTADO[u.estado][1]}>{ESTADO[u.estado][0]}</Chip></td>
                      <td>{u.ultimo_acceso ? formatoFecha(u.ultimo_acceso) : <span className="sub">Aún no ingresa</span>}</td>
                      <td className="acciones">
                        {propio ? null : u.estado === "invitado" ? (
                          <button className="btn sec chico" onClick={() => accion(() => api("POST", `/api/usuarios/${u.id}/reenviar`), "Invitación reenviada.")}>Reenviar invitación</button>
                        ) : u.estado === "activo" ? (
                          <button className="btn peligro chico" onClick={() => confirm("¿Bloquear la cuenta? Se cierran sus sesiones y no podrá ingresar.") && accion(() => api("POST", `/api/usuarios/${u.id}/bloquear`), "Cuenta bloqueada.")}>Bloquear</button>
                        ) : (
                          <button className="btn sec chico" onClick={() => accion(() => api("POST", `/api/usuarios/${u.id}/desbloquear`), "Cuenta desbloqueada.")}>Desbloquear</button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}
      {invitar ? (
        <Invitar
          empresaId={empresaId}
          onCerrar={() => setInvitar(false)}
          onListo={(m) => {
            setInvitar(false);
            setAviso(m);
            recargar();
          }}
        />
      ) : null}
    </>
  );
}

function Invitar(p: { empresaId: number; onCerrar(): void; onListo(mensaje: string): void }) {
  const comites = useDatos(() => api<ComiteFila[]>("GET", `/api/comites?empresa_id=${p.empresaId}&estado=activo`), [p.empresaId]);
  const [f, setF] = useState({ rut: "", nombres: "", apellidos: "", correo: "", rol: "COORDINADOR", comite_id: "" });
  const cambiar = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const rutMal = f.rut !== "" && !rutValido(f.rut);
  return (
    <Dialogo
      titulo="Invitar usuario"
      boton="Enviar invitación"
      onCerrar={p.onCerrar}
      onEnviar={async () => {
        if (!rutValido(f.rut)) throw new Error("Revise el RUT y su dígito verificador.");
        const r = await api<{ invitacion_enviada: boolean }>("POST", `/api/empresas/${p.empresaId}/usuarios`, {
          rut: normalizarRut(f.rut),
          nombres: f.nombres,
          apellidos: f.apellidos,
          correo: f.correo,
          rol: f.rol,
          comite_id: f.rol === "COORDINADOR" && f.comite_id ? Number(f.comite_id) : undefined,
        });
        p.onListo(r.invitacion_enviada ? `Invitación enviada a ${f.correo}.` : "La persona ya tenía cuenta: se le agregó el acceso.");
      }}
    >
      <div className="campos">
        <Campo etiqueta="RUT" id="u-rut" error={rutMal ? "RUT o dígito verificador no válido" : undefined} ayuda="Será su nombre de usuario">
          <input id="u-rut" value={f.rut} onChange={cambiar("rut")} required placeholder="12.345.678-5" />
        </Campo>
        <Campo etiqueta="Correo" id="u-correo"><input id="u-correo" type="email" value={f.correo} onChange={cambiar("correo")} required /></Campo>
        <Campo etiqueta="Nombres" id="u-nombres"><input id="u-nombres" value={f.nombres} onChange={cambiar("nombres")} required /></Campo>
        <Campo etiqueta="Apellidos" id="u-apellidos"><input id="u-apellidos" value={f.apellidos} onChange={cambiar("apellidos")} required /></Campo>
        <Campo etiqueta="Rol" id="u-rol">
          <select id="u-rol" value={f.rol} onChange={cambiar("rol")}>
            <option value="ADMIN_EMPRESA">Administrador</option>
            <option value="COORDINADOR">Coordinador</option>
            <option value="AUDITOR">Auditor (solo lectura)</option>
          </select>
        </Campo>
        {f.rol === "COORDINADOR" ? (
          <Campo etiqueta="Comité" id="u-comite">
            <select id="u-comite" value={f.comite_id} onChange={cambiar("comite_id")}>
              <option value="">Todos los comités</option>
              {(comites.datos ?? []).map((c) => <option key={c.id} value={c.id}>{c.nombre}</option>)}
            </select>
          </Campo>
        ) : null}
      </div>
    </Dialogo>
  );
}
