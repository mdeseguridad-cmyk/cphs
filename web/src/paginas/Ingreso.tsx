import { useState, type FormEvent } from "react";
import { autenticador, mensajeError, type Paso } from "../auth/autenticador";
import type { Config } from "../config";
import { AvisoError, Campo, icono } from "../componentes";
import { normalizarRut, rutValido } from "../util";

export function Ingreso(p: { config: Config; errorInicial?: unknown; onListo(): void }) {
  const [paso, setPaso] = useState<Paso["tipo"] | "credenciales">("credenciales");
  const [rut, setRut] = useState("");
  const [clave, setClave] = useState("");
  const [clave2, setClave2] = useState("");
  const [codigo, setCodigo] = useState("");
  const [error, setError] = useState<unknown>(p.errorInicial ?? null);
  const [enviando, setEnviando] = useState(false);
  const desarrollo = p.config.auth === "desarrollo";

  async function avanzar(fn: () => Promise<Paso>) {
    setEnviando(true);
    setError(null);
    try {
      const r = await fn();
      if (r.tipo === "listo") p.onListo();
      else setPaso(r.tipo);
    } catch (e) {
      setError(new Error(mensajeError(e)));
    } finally {
      setEnviando(false);
    }
  }

  function enviar(e: FormEvent) {
    e.preventDefault();
    const a = autenticador();
    if (paso === "credenciales") {
      if (!rutValido(rut)) return setError(new Error("Revise el RUT y su dígito verificador."));
      return avanzar(() => a.iniciar(normalizarRut(rut), clave));
    }
    if (paso === "nueva_clave") {
      if (clave2.length < 10) return setError(new Error("La contraseña debe tener al menos 10 caracteres."));
      return avanzar(() => a.nuevaClave(clave2));
    }
    return avanzar(() => a.codigoMfa(codigo.trim()));
  }

  return (
    <div className="ingreso">
      <div className="caja">
        <div className="marca">
          <span className="logo">{icono.logo}</span>
          <div>
            <b>Paritario</b>
            <span>Comités paritarios</span>
          </div>
        </div>
        <div className="tarjeta">
          <div className="tb">
            <AvisoError error={error} />
            <form onSubmit={enviar}>
              {paso === "credenciales" ? (
                <>
                  <Campo etiqueta="RUT" id="rut" ayuda="Con guion, por ejemplo 12.345.678-5">
                    <input id="rut" autoComplete="username" value={rut} onChange={(e) => setRut(e.target.value)} required />
                  </Campo>
                  {desarrollo ? (
                    <div className="aviso warn">Modo desarrollo: basta el RUT de un usuario de la base.</div>
                  ) : (
                    <Campo etiqueta="Contraseña" id="clave">
                      <input id="clave" type="password" autoComplete="current-password" value={clave} onChange={(e) => setClave(e.target.value)} required />
                    </Campo>
                  )}
                </>
              ) : paso === "nueva_clave" ? (
                <>
                  <p style={{ margin: 0 }}>Es su primer ingreso: defina su contraseña.</p>
                  <Campo etiqueta="Contraseña nueva" id="clave2" ayuda="Al menos 10 caracteres, con mayúsculas, minúsculas y números.">
                    <input id="clave2" type="password" autoComplete="new-password" value={clave2} onChange={(e) => setClave2(e.target.value)} required />
                  </Campo>
                </>
              ) : (
                <Campo etiqueta="Código de verificación" id="codigo" ayuda="El código de 6 dígitos de su aplicación autenticadora.">
                  <input id="codigo" inputMode="numeric" autoComplete="one-time-code" value={codigo} onChange={(e) => setCodigo(e.target.value)} required />
                </Campo>
              )}
              <button className="btn" type="submit" disabled={enviando}>
                {enviando ? "Ingresando…" : "Ingresar"}
              </button>
            </form>
            {paso === "credenciales" && p.config.proveedores.length ? (
              <>
                <div className="sep">o ingrese con</div>
                <div className="proveedores">
                  {p.config.proveedores.map((pr) => (
                    <button key={pr.nombre} className="btn sec" type="button" onClick={() => autenticador().federado(pr.nombre).catch((e) => setError(e))}>
                      {pr.etiqueta}
                    </button>
                  ))}
                </div>
              </>
            ) : null}
          </div>
        </div>
      </div>
    </div>
  );
}
