import { StrictMode, useCallback, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, NavLink, Navigate, Route, Routes, useLocation } from "react-router-dom";
import "./estilos.css";
import { ErrorApi, siLaSesionExpira } from "./api";
import { autenticador, crearAutenticador } from "./auth/autenticador";
import { cargarConfig, type Config } from "./config";
import { AvisoError, Cargando, icono } from "./componentes";
import { NOMBRE_ROL, ProveedorSesion, cargarSesion, useSesion, type Empresa, type Yo } from "./sesion";
import { Ingreso } from "./paginas/Ingreso";
import { Panel } from "./paginas/Panel";
import { Comites } from "./paginas/Comites";
import { Comite } from "./paginas/Comite";
import { Centros } from "./paginas/Centros";
import { Usuarios } from "./paginas/Usuarios";

type Estado =
  | { fase: "cargando" }
  | { fase: "error"; error: unknown }
  | { fase: "ingreso"; config: Config; error?: unknown; intento: number }
  | { fase: "listo"; config: Config; yo: Yo; empresas: Empresa[] };

function Raiz() {
  const [estado, setEstado] = useState<Estado>({ fase: "cargando" });

  const entrar = useCallback(async (config: Config) => {
    try {
      const s = await cargarSesion();
      setEstado({ fase: "listo", config, ...s });
    } catch (e) {
      // 403: cuenta sin usuario en Paritario o bloqueada.
      autenticador().cerrar();
      setEstado({ fase: "ingreso", config, error: e instanceof ErrorApi && e.status !== 401 ? e : undefined, intento: Date.now() });
    }
  }, []);

  useEffect(() => {
    (async () => {
      const config = await cargarConfig();
      const auth = crearAutenticador(config);
      siLaSesionExpira(() => {
        auth.cerrar();
        setEstado({ fase: "ingreso", config, intento: Date.now() });
      });
      if (location.pathname === "/auth/callback") {
        try {
          await auth.completarFederado(new URL(location.href));
        } finally {
          history.replaceState(null, "", "/");
        }
      }
      if (await auth.token()) await entrar(config);
      else setEstado({ fase: "ingreso", config, intento: Date.now() });
    })().catch((error) => setEstado({ fase: "error", error }));
  }, [entrar]);

  switch (estado.fase) {
    case "cargando":
      return <Cargando />;
    case "error":
      return (
        <div className="contenido">
          <AvisoError error={estado.error} />
        </div>
      );
    case "ingreso":
      // La clave remonta el formulario para mostrar un error nuevo.
      return <Ingreso key={estado.intento} config={estado.config} errorInicial={estado.error} onListo={() => entrar(estado.config)} />;
    case "listo":
      return (
        <ProveedorSesion
          yo={estado.yo}
          empresas={estado.empresas}
          salir={() => {
            autenticador().cerrar();
            setEstado({ fase: "ingreso", config: estado.config, intento: Date.now() });
          }}
        >
          <BrowserRouter>
            <Marco entorno={estado.config.entorno} />
          </BrowserRouter>
        </ProveedorSesion>
      );
  }
}

function Marco(p: { entorno: string }) {
  const s = useSesion();
  const [abierta, setAbierta] = useState(false);
  const ubicacion = useLocation();
  useEffect(() => setAbierta(false), [ubicacion.pathname]);
  const admin = s.esAdmin(s.empresaId);
  const nombre = [s.yo.nombres, s.yo.apellidos].filter(Boolean).join(" ") || s.yo.rut;
  const rolesVisibles = [...new Set(s.yo.roles.filter((r) => s.empresaId === null || r.empresa_id === s.empresaId || r.organismo_id !== null).map((r) => NOMBRE_ROL[r.rol]))];
  const titulos: Record<string, string> = { "/": "Panel", "/comites": "Comités", "/centros": "Centros de trabajo", "/usuarios": "Usuarios y accesos" };
  const titulo = titulos[ubicacion.pathname] ?? (ubicacion.pathname.startsWith("/comites/") ? "Comité" : "");

  return (
    <div className="app">
      <aside className={`lateral ${abierta ? "abierta" : ""}`} aria-label="Navegación">
        <div className="marca">
          <span className="logo">{icono.logo}</span>
          <div>
            <b>Paritario</b>
            <span>Comités paritarios{p.entorno !== "produccion" ? ` · ${p.entorno}` : ""}</span>
          </div>
        </div>
        <nav className="nav">
          <NavLink to="/" end>{icono.panel}Panel</NavLink>
          <NavLink to="/comites">{icono.comites}Comités</NavLink>
          {s.empresaId !== null ? (
            <>
              <div className="grupo">Empresa</div>
              <NavLink to="/centros">{icono.centros}Centros de trabajo</NavLink>
              {admin ? <NavLink to="/usuarios">{icono.usuarios}Usuarios y accesos</NavLink> : null}
            </>
          ) : null}
        </nav>
        <div className="pie">
          <b>{nombre}</b>
          <span className="rol">{rolesVisibles.join(" · ")}</span>
          <div>
            <button className="btn sec chico" onClick={s.salir}>Cerrar sesión</button>
          </div>
        </div>
      </aside>
      <div className={`velo ${abierta ? "visible" : ""}`} onClick={() => setAbierta(false)} />
      <div className="principal">
        <header className="superior">
          <button className="menu" aria-label="Abrir menú" onClick={() => setAbierta(true)}>{icono.menu}</button>
          <span className="titulo">{titulo}</span>
          {s.empresas.length > 1 || s.esOrganismo ? (
            <select
              aria-label="Empresa"
              value={s.empresaId ?? ""}
              onChange={(e) => s.elegirEmpresa(e.target.value ? Number(e.target.value) : null)}
            >
              {s.esOrganismo ? <option value="">Todas las empresas</option> : null}
              {s.empresas.map((e) => (
                <option key={e.id} value={e.id}>{e.razon_social}</option>
              ))}
            </select>
          ) : null}
        </header>
        <main className="contenido">
          <Routes>
            <Route path="/" element={<Panel />} />
            <Route path="/comites" element={<Comites />} />
            <Route path="/comites/:id" element={<Comite />} />
            <Route path="/centros" element={s.empresaId !== null ? <Centros /> : <Navigate to="/" />} />
            <Route path="/usuarios" element={admin ? <Usuarios /> : <Navigate to="/" />} />
            <Route path="*" element={<Navigate to="/" />} />
          </Routes>
        </main>
      </div>
    </div>
  );
}

createRoot(document.getElementById("raiz")!).render(
  <StrictMode>
    <Raiz />
  </StrictMode>,
);
