// Prueba de punta a punta del front: navegador real (Playwright) contra la
// API real y PostgreSQL con seguridad por fila. Cognito se reemplaza por los
// tokens de desarrollo y S3 por un servidor local que verifica la huella
// SHA-256 de cada archivo, como lo hace S3.
//
// Uso: npm run e2e   (requiere la base de pruebas de la API: PGTEST_*)
// Capturas en E2E_CAPTURAS (por defecto, test/capturas/).

import { createHash } from "node:crypto";
import { createServer as servidorHttp } from "node:http";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { createServer as servidorVite } from "vite";
import react from "@vitejs/plugin-react";
import { createLocalJWKSet } from "jose";
import { createRequire } from "node:module";
import { AlmacenMemoria, baseDisponible, prepararBase, sqlAdmin, BASE } from "../../api/test/entorno.ts";
import { construirApp } from "../../api/src/app.ts";
import { verificadorCognito } from "../../api/src/auth.ts";
import { leerConfig } from "../../api/src/config.ts";
import { crearPool } from "../../api/src/db.ts";
import { CLIENTE_DEV, EMISOR_DEV, crearClavesDev, pluginTokensDesarrollo } from "../dev/tokens.ts";

// Playwright viene instalado en el sistema (o en devDependencies).
const { chromium } = createRequire(import.meta.url)("playwright") as typeof import("playwright");
type Page = import("playwright").Page;
const WEB = resolve(import.meta.dirname, "..");
const CAPTURAS = process.env.E2E_CAPTURAS ?? resolve(WEB, "test/capturas");
const P_API = 8091, P_S3 = 8092, P_WEB = 5174;
mkdirSync(CAPTURAS, { recursive: true });

declare global {
  // eslint-disable-next-line no-var
  var paginaActual: import("playwright").Page | undefined;
}
let fallas = 0;
let pasos = 0;
async function paso(nombre: string, fn: () => Promise<void>) {
  pasos++;
  try {
    await fn();
    console.log(`ok   ${nombre}`);
  } catch (e) {
    fallas++;
    await globalThis.paginaActual?.screenshot({ path: `${CAPTURAS}/falla-${pasos}.png` }).catch(() => undefined);
    console.log(`FALLA ${nombre}\n     ${(e as Error).message.split("\n").slice(0, 4).join("\n     ")}`);
  }
}

if (!(await baseDisponible())) {
  console.log("Sin base de pruebas (PGTEST_*): se omite la prueba de punta a punta.");
  process.exit(0);
}

// --- Base, API, S3 y Vite ------------------------------------------------------------
prepararBase();
// Los usuarios entran con tokens de desarrollo: su cuenta se une en el primer ingreso.
await sqlAdmin("UPDATE usuario SET cognito_sub = NULL, estado = 'invitado' WHERE estado = 'activo'");

const claves = await crearClavesDev();
const almacen = new (class extends AlmacenMemoria {
  override async urlSubida(b: string, k: string, o: { tipo: string; tamano: number; sha256Base64: string }) {
    return { url: `http://localhost:${P_S3}/${b}/${k}`, encabezados: { "content-type": o.tipo, "x-amz-checksum-sha256": o.sha256Base64 } };
  }
  override async urlDescarga(b: string, k: string) {
    return `http://localhost:${P_S3}/${b}/${k}`;
  }
})();
const archivos = new Map<string, Buffer>();
const s3 = servidorHttp((req, res) => {
  res.setHeader("access-control-allow-origin", "*");
  res.setHeader("access-control-allow-methods", "PUT, GET");
  res.setHeader("access-control-allow-headers", "content-type, x-amz-checksum-sha256");
  if (req.method === "OPTIONS") return res.end();
  const ruta = decodeURIComponent((req.url ?? "").slice(1));
  if (req.method === "GET") return res.end(archivos.get(ruta) ?? "");
  const partes: Buffer[] = [];
  req.on("data", (d: Buffer) => partes.push(d));
  req.on("end", () => {
    const cuerpo = Buffer.concat(partes);
    const sha = createHash("sha256").update(cuerpo).digest("base64");
    if (sha !== req.headers["x-amz-checksum-sha256"]) {
      res.statusCode = 400;
      return res.end("BadDigest");
    }
    archivos.set(ruta, cuerpo);
    almacen.subidos.set(ruta, { tamano: cuerpo.length, sha256Base64: sha });
    res.end();
  });
});
await new Promise<void>((r) => s3.listen(P_S3, r));

const cfg = leerConfig({
  DB_HOST: process.env.PGTEST_HOST ?? "localhost",
  DB_PORT: process.env.PGTEST_PORT ?? "54330",
  DB_NAME: BASE,
  DB_AUTH: "clave",
  DB_PASSWORD: "clave-de-prueba",
  DB_SSLMODE: "disable",
  DOCUMENTOS_BUCKET: "documentos",
  OPERACIONES_BUCKET: "operaciones",
  COGNITO_EMISOR: EMISOR_DEV,
  COGNITO_CLIENT_ID: CLIENTE_DEV,
});
const nada = async () => {};
const pool = crearPool(cfg);
const api = construirApp({
  cfg,
  pool,
  servicios: {
    almacen,
    correo: { enviar: nada },
    identidad: { crear: nada, reenviarInvitacion: nada, deshabilitar: nada, habilitar: nada },
    secretos: { leer: async () => "{}" },
    http: fetch,
  },
  verificarToken: verificadorCognito(cfg, createLocalJWKSet(claves.jwks as never)),
  registro: false,
});
await api.listen({ port: P_API });

const vite = await servidorVite({
  configFile: false,
  root: WEB,
  logLevel: "error",
  plugins: [react(), pluginTokensDesarrollo({ claves })],
  define: { global: "globalThis" },
  server: { port: P_WEB, strictPort: true, proxy: { "/api": `http://localhost:${P_API}` } },
});
await vite.listen();
const URL_WEB = `http://localhost:${P_WEB}`;

// --- Navegador ---------------------------------------------------------------------
const navegador = await chromium.launch();
const contexto = await navegador.newContext({ viewport: { width: 1280, height: 860 }, deviceScaleFactor: 1 });
const p = await contexto.newPage();
(globalThis as { paginaActual?: Page }).paginaActual = p;
const erroresConsola: string[] = [];
p.on("pageerror", (e) => erroresConsola.push(e.message));

async function ingresar(pg: Page, rut: string) {
  await pg.goto(URL_WEB);
  await pg.getByLabel("RUT").fill(rut);
  await pg.getByRole("button", { name: "Ingresar" }).click();
}
async function salir(pg: Page) {
  await pg.getByRole("button", { name: "Cerrar sesión" }).click();
  await pg.getByRole("button", { name: "Ingresar" }).waitFor();
}
const captura = (pg: Page, nombre: string) => pg.screenshot({ path: `${CAPTURAS}/${nombre}.png`, fullPage: true });
const dialogo = (pg: Page) => pg.getByRole("dialog");

await paso("una cuenta sin usuario en Paritario no entra", async () => {
  await ingresar(p, "11.111.111-1");
  await p.getByRole("alert").getByText("Cuenta sin usuario en Paritario").waitFor();
});

await paso("el RUT se valida antes de enviar", async () => {
  await p.getByLabel("RUT").fill("15.151.515-1");
  await p.getByRole("button", { name: "Ingresar" }).click();
  await p.getByText("Revise el RUT").waitFor();
  await captura(p, "01-ingreso");
});

await paso("el administrador entra y ve el panel de su empresa", async () => {
  await ingresar(p, "15.151.515-0");
  await p.getByRole("heading", { name: "Panel" }).waitFor();
  await p.getByRole("cell", { name: "C1" }).waitFor();
  await p.getByRole("link", { name: "Usuarios y accesos" }).waitFor();
});

await paso("crea un comité nuevo en un centro de trabajo", async () => {
  await p.getByRole("link", { name: "Comités" }).click();
  await p.getByRole("button", { name: "Nuevo comité" }).click();
  await dialogo(p).getByLabel("Nombre").fill("CPHS Bodega Central");
  await dialogo(p).getByLabel("Centro de trabajo").selectOption({ label: "Planta Norte · Antofagasta" });
  await dialogo(p).getByRole("button", { name: "Crear comité" }).click();
  await p.getByRole("heading", { name: "CPHS Bodega Central" }).waitFor();
});

await paso("agrega integrantes y muestra la regla del presidente único", async () => {
  await p.getByRole("link", { name: "Comités" }).click();
  await p.getByRole("cell", { name: "C1", exact: true }).click();
  await p.getByRole("tab", { name: "Integrantes" }).click();
  for (const [rut, nombre, cargo] of [["11.111.111-1", "Ana", "presidente"], ["22.222.222-2", "Beto", "presidente"]] as const) {
    await p.getByRole("button", { name: "Agregar" }).click();
    const d = dialogo(p);
    await d.getByLabel("RUT").fill(rut);
    await d.getByLabel("Nombres").fill(nombre);
    await d.getByLabel("Apellidos").fill("Prueba");
    await d.getByLabel("Cargo").selectOption(cargo);
    await d.getByRole("button", { name: "Agregar" }).click();
    if (nombre === "Beto") {
      await d.getByRole("alert").getByText("ya tiene un presidente").waitFor();
      await d.getByLabel("Cargo").selectOption("secretario");
      await d.getByRole("button", { name: "Agregar" }).click();
    }
    await d.waitFor({ state: "detached" });
  }
  await p.getByRole("cell", { name: /Ana Prueba/ }).waitFor();
  await p.getByRole("cell", { name: /Beto Prueba/ }).waitFor();
  await captura(p, "02-integrantes");
});

await paso("crea una comisión con integrantes", async () => {
  await p.getByRole("tab", { name: "Comisiones" }).click();
  await p.getByRole("button", { name: "Nueva comisión" }).click();
  await dialogo(p).getByLabel("Tipo").selectOption("capacitacion_difusion");
  await dialogo(p).getByRole("button", { name: "Crear" }).click();
  await p.getByRole("button", { name: "Integrantes" }).click();
  await dialogo(p).getByLabel(/Ana Prueba/).check();
  await dialogo(p).getByRole("button", { name: "Guardar" }).click();
  await p.getByRole("cell", { name: "Ana Prueba" }).waitFor();
});

await paso("crea el programa desde la plantilla y avanza una actividad", async () => {
  await p.getByRole("tab", { name: "Programa de trabajo" }).click();
  await p.getByRole("button", { name: /Usar «Programa general de construcción»/ }).click();
  await p.getByText("Inspección de andamios").waitFor();
  const ficha = p.locator(".ficha", { hasText: "Inspección de andamios" });
  await ficha.getByRole("button", { name: "Iniciar" }).click();
  await p.getByRole("region", { name: "En ejecución" }).getByText("Inspección de andamios").waitFor();
  await p.locator(".ficha", { hasText: "Inspección de andamios" }).getByRole("button", { name: "Cerrar" }).click();
  await p.getByRole("region", { name: "Cerrado" }).getByText("Inspección de andamios").waitFor();
  await captura(p, "03-programa");
});

await paso("sube el acta: S3 verifica la huella y queda disponible", async () => {
  await p.getByRole("tab", { name: "Documentos" }).click();
  await p.getByRole("button", { name: "Subir documento" }).click();
  await dialogo(p).getByLabel("Archivo").setInputFiles({ name: "Acta enero.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF-1.7 acta de enero") });
  await dialogo(p).getByRole("button", { name: "Subir" }).click();
  await dialogo(p).waitFor({ state: "detached" });
  await p.getByRole("cell", { name: /Acta enero/ }).waitFor();
  await p.getByRole("button", { name: "Descargar" }).waitFor();
});

await paso("crea el cronograma, registra la reunión con su acta y asistencia", async () => {
  await p.getByRole("tab", { name: "Reuniones" }).click();
  await p.getByRole("button", { name: /Crear cronograma/ }).click();
  await p.getByRole("cell", { name: "Diciembre" }).waitFor();
  await p.getByRole("button", { name: "Registrar" }).first().click();
  await dialogo(p).getByLabel("Acta").selectOption({ label: "Acta enero" });
  await dialogo(p).getByRole("button", { name: "Guardar" }).click();
  await dialogo(p).waitFor({ state: "detached" });
  await p.getByRole("button", { name: "Asistencia" }).click();
  await dialogo(p).getByLabel(/Beto Prueba/).uncheck();
  await dialogo(p).getByLabel("Justificación de Beto").fill("Licencia médica");
  await dialogo(p).getByRole("button", { name: "Guardar asistencia" }).click();
  await dialogo(p).waitFor({ state: "detached" });
  await p.locator("tr", { hasText: "Enero" }).getByRole("cell", { name: "1", exact: true }).first().waitFor();
  await captura(p, "04-reuniones");
});

await paso("el resumen muestra la paridad y el cumplimiento", async () => {
  await p.getByRole("tab", { name: "Resumen" }).click();
  await p.getByText("Paridad", { exact: true }).waitFor();
  await p.getByText(/Cumplimiento \d{4}: [\d.]+%/).waitFor();
});

await paso("invita a un usuario", async () => {
  await p.getByRole("link", { name: "Usuarios y accesos" }).click();
  await p.getByRole("button", { name: "Invitar usuario" }).click();
  const d = dialogo(p);
  await d.getByLabel("RUT").fill("21.212.121-5");
  await d.getByLabel("Correo").fill("nueva@empresa1.cl");
  await d.getByLabel("Nombres").fill("Nueva");
  await d.getByLabel("Apellidos").fill("Persona");
  await d.getByLabel("Rol").selectOption("AUDITOR");
  await d.getByRole("button", { name: "Enviar invitación" }).click();
  await p.getByText("Invitación enviada a nueva@empresa1.cl").waitFor();
  await p.locator("tr", { hasText: "Nueva Persona" }).getByText("Invitación enviada").waitFor();
  await captura(p, "05-usuarios");
});

await paso("centros de trabajo de la empresa", async () => {
  await p.getByRole("link", { name: "Centros de trabajo" }).click();
  await p.getByRole("cell", { name: /Planta Norte/ }).waitFor();
  await salir(p);
});

await paso("el coordinador de C1 no administra usuarios ni otros comités", async () => {
  await ingresar(p, "16.161.616-8");
  await p.getByRole("heading", { name: "Panel" }).waitFor();
  if (await p.getByRole("link", { name: "Usuarios y accesos" }).count()) throw new Error("ve Usuarios y accesos");
  await p.getByRole("link", { name: "Comités" }).click();
  await p.getByRole("cell", { name: "C1", exact: true }).waitFor();
  if (await p.getByRole("cell", { name: "CPHS Bodega Central" }).count()) throw new Error("ve un comité que no es suyo");
  if (await p.getByRole("button", { name: "Nuevo comité" }).count()) throw new Error("puede crear comités");
  await salir(p);
});

await paso("el auditor solo lee", async () => {
  await ingresar(p, "12.345.678-5");
  await p.getByRole("link", { name: "Comités" }).click();
  await p.getByRole("cell", { name: "C1", exact: true }).click();
  await p.getByRole("tab", { name: "Integrantes" }).click();
  await p.getByRole("cell", { name: /Ana Prueba/ }).waitFor();
  if (await p.getByRole("button", { name: "Agregar" }).count()) throw new Error("el auditor puede agregar");
  if (await p.getByRole("button", { name: "Editar" }).count()) throw new Error("el auditor puede editar");
  await salir(p);
});

await paso("el organismo ve todas sus empresas, sin personas", async () => {
  await ingresar(p, "14.141.414-3");
  await p.getByRole("heading", { name: "Panel" }).waitFor();
  await p.getByRole("combobox", { name: "Empresa" }).waitFor();
  await p.getByRole("columnheader", { name: "Empresa" }).waitFor();
  await p.getByRole("cell", { name: "C1", exact: true }).click();
  await p.getByRole("tab", { name: "Programa de trabajo" }).waitFor();
  if (await p.getByRole("tab", { name: "Integrantes" }).count()) throw new Error("el organismo ve integrantes");
  await captura(p, "06-organismo");
  await salir(p);
});

await paso("teléfono en modo oscuro", async () => {
  const movil = await navegador.newContext({ viewport: { width: 390, height: 844 }, colorScheme: "dark", deviceScaleFactor: 1 });
  const m = await movil.newPage();
  m.on("pageerror", (e) => erroresConsola.push(e.message));
  await ingresar(m, "15.151.515-0");
  await m.getByRole("heading", { name: "Panel" }).waitFor();
  const ancho = await m.evaluate(() => document.documentElement.scrollWidth);
  if (ancho > 390) throw new Error(`desborde horizontal: ${ancho}px`);
  await m.getByRole("button", { name: "Abrir menú" }).click();
  await m.getByRole("link", { name: "Comités" }).click();
  await m.getByRole("cell", { name: "C1", exact: true }).click();
  await m.getByRole("tab", { name: "Programa de trabajo" }).click();
  await m.getByText("Inspección de andamios").waitFor();
  await captura(m, "07-movil-programa");
  await movil.close();
});

await paso("sin errores de JavaScript en la página", async () => {
  if (erroresConsola.length) throw new Error(erroresConsola.join("\n"));
});

await navegador.close();
await vite.close();
await api.close();
await pool.end();
s3.close();
console.log(`\n${pasos - fallas} de ${pasos} pasos correctos · capturas en ${CAPTURAS}`);
process.exit(fallas ? 1 : 0);
