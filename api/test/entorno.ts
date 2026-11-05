// Entorno de pruebas: una base PostgreSQL real (con seguridad por fila), la
// carga hecha con infra/scripts/carga/cargar.sh, tokens firmados con claves
// de prueba y servicios de AWS en memoria.
//
// Variables (con valores por defecto para la base de pruebas local):
//   PGTEST_HOST, PGTEST_PORT, PGTEST_USER, PGTEST_PASSWORD

import { execFileSync } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import pg from "pg";
import { generateKeyPair, exportJWK, SignJWT, createLocalJWKSet } from "jose";
import { construirApp } from "../src/app.js";
import { verificadorCognito, olvidarIngresos } from "../src/auth.js";
import { leerConfig, type Config } from "../src/config.js";
import { crearPool } from "../src/db.js";
import type { Almacen, Servicios } from "../src/servicios.js";

const RAIZ = resolve(import.meta.dirname, "../..");
export const BASE = "paritario_api_prueba";
const admin = {
  host: process.env.PGTEST_HOST ?? "localhost",
  port: Number(process.env.PGTEST_PORT ?? 54330),
  user: process.env.PGTEST_USER ?? "maestro",
  password: process.env.PGTEST_PASSWORD ?? "maestro",
};
const CLAVE_APP = "clave-de-prueba";

function psql(base: string, args: string[], env: Record<string, string> = {}) {
  return execFileSync("psql", ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", base, ...args], {
    env: { ...process.env, PGHOST: admin.host, PGPORT: String(admin.port), PGUSER: admin.user, PGPASSWORD: admin.password, PGSSLMODE: "disable", ...env },
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export async function baseDisponible(): Promise<boolean> {
  const c = new pg.Client({ ...admin, database: "postgres" });
  try {
    await c.connect();
    await c.end();
    return true;
  } catch {
    return false;
  }
}

/** Crea la base desde cero con el script de carga real, más los datos de prueba. */
export function prepararBase(): void {
  psql("postgres", ["-c", `DROP DATABASE IF EXISTS ${BASE}`, "-c", `CREATE DATABASE ${BASE}`]);
  const dir = mkdtempSync(join(tmpdir(), "carga-"));
  mkdirSync(join(dir, "carga", "db"), { recursive: true });
  cpSync(join(RAIZ, "infra/scripts/carga/cargar.sh"), join(dir, "carga/cargar.sh"));
  for (const f of readdirSync(join(RAIZ, "db"))) {
    if (f === "schema.sql" || f.startsWith("seed")) cpSync(join(RAIZ, "db", f), join(dir, "carga/db", f));
  }
  execFileSync("sh", [join(dir, "carga/cargar.sh")], {
    env: { ...process.env, PGHOST: admin.host, PGPORT: String(admin.port), PGUSER: admin.user, PGPASSWORD: admin.password, PGSSLMODE: "disable", PGDATABASE: BASE },
    stdio: ["ignore", "pipe", "pipe"],
  });
  // En RDS el rol entra con IAM; en la prueba, con clave.
  psql(BASE, ["-c", `ALTER ROLE paritario_app PASSWORD '${CLAVE_APP}'`]);
  psql(BASE, ["-f", join(import.meta.dirname, "datos.sql")]);
}

export async function sqlAdmin<T extends pg.QueryResultRow = pg.QueryResultRow>(sql: string, params: unknown[] = []): Promise<T[]> {
  const c = new pg.Client({ ...admin, database: BASE });
  await c.connect();
  try {
    await c.query("SET search_path = paritario, public");
    return (await c.query<T>(sql, params)).rows;
  } finally {
    await c.end();
  }
}

// --- Servicios en memoria -----------------------------------------------------------

export class AlmacenMemoria implements Almacen {
  objetos = new Map<string, string>();
  subidos = new Map<string, { tamano: number; sha256Base64: string }>();
  async poner(b: string, k: string, cuerpo: string) {
    this.objetos.set(`${b}/${k}`, cuerpo);
  }
  async leer(b: string, k: string) {
    const v = this.objetos.get(`${b}/${k}`);
    if (v === undefined) throw new Error(`No existe ${b}/${k}`);
    return v;
  }
  async borrar(b: string, k: string) {
    this.objetos.delete(`${b}/${k}`);
  }
  async urlSubida(b: string, k: string, o: { tipo: string; tamano: number; sha256Base64: string }) {
    return { url: `https://s3.prueba/${b}/${k}`, encabezados: { "content-type": o.tipo, "x-amz-checksum-sha256": o.sha256Base64 } };
  }
  async urlDescarga(b: string, k: string) {
    return `https://s3.prueba/${b}/${k}?descarga`;
  }
  async cabecera(b: string, k: string) {
    const s = this.subidos.get(`${b}/${k}`);
    return s ? { ...s, version: "v1" } : null;
  }
  claves(prefijo: string): string[] {
    return [...this.objetos.keys()].filter((k) => k.includes(prefijo));
  }
}

export interface Prueba {
  cfg: Config;
  pool: pg.Pool;
  servicios: Servicios & { almacen: AlmacenMemoria };
  llamadas: { tipo: string; datos: unknown }[];
  respuestaCliente: { estado: number; cuerpo: unknown };
  app: ReturnType<typeof construirApp>;
  token(o: { sub: string; usuario?: string; proveedor?: string; rut?: string; rol?: string; contratos?: string }): Promise<string>;
  cerrar(): Promise<void>;
}

export async function crearPrueba(modo: "api" | "trabajos" = "api"): Promise<Prueba> {
  const cfg = leerConfig({
    MODO: modo,
    DB_HOST: admin.host,
    DB_PORT: String(admin.port),
    DB_NAME: BASE,
    DB_USER: "paritario_app",
    DB_AUTH: "clave",
    DB_PASSWORD: CLAVE_APP,
    DB_SSLMODE: "disable",
    DOCUMENTOS_BUCKET: "documentos",
    OPERACIONES_BUCKET: "operaciones",
    COGNITO_EMISOR: "https://cognito.prueba/pool",
    COGNITO_CLIENT_ID: "cliente-spa",
    COGNITO_USER_POOL_ID: "pool",
  });
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "prueba", alg: "RS256" };
  const verificarToken = verificadorCognito(cfg, createLocalJWKSet({ keys: [jwk] }));
  const llamadas: Prueba["llamadas"] = [];
  const respuestaCliente: Prueba["respuestaCliente"] = { estado: 200, cuerpo: [] };
  const anota = (tipo: string) => async (datos: unknown) => {
    llamadas.push({ tipo, datos });
  };
  const servicios = {
    almacen: new AlmacenMemoria(),
    correo: { enviar: anota("correo") },
    identidad: { crear: anota("crear"), reenviarInvitacion: anota("reenviar"), deshabilitar: anota("deshabilitar"), habilitar: anota("habilitar") },
    secretos: { leer: async (n: string) => JSON.stringify({ url: `https://cliente.prueba/${n}`, token: "secreto" }) },
    http: (async (url: string, init?: RequestInit) => {
      llamadas.push({ tipo: "http", datos: { url, headers: init?.headers } });
      return new Response(JSON.stringify(respuestaCliente.cuerpo), { status: respuestaCliente.estado });
    }) as typeof fetch,
  };
  const pool = crearPool(cfg);
  const app = construirApp({ cfg, pool, servicios, verificarToken, registro: false });
  olvidarIngresos();
  return {
    cfg,
    pool,
    servicios,
    llamadas,
    respuestaCliente,
    app,
    async token(o) {
      const reclamos: Record<string, unknown> = { token_use: "id", "cognito:username": o.usuario ?? o.rut ?? "" };
      if (o.proveedor) reclamos.identities = [{ providerName: o.proveedor, userId: "x" }];
      if (o.rut) reclamos["custom:rut"] = o.rut;
      if (o.rol) reclamos["custom:rol_externo"] = o.rol;
      if (o.contratos) reclamos["custom:contratos"] = o.contratos;
      return new SignJWT(reclamos)
        .setProtectedHeader({ alg: "RS256", kid: "prueba" })
        .setSubject(o.sub)
        .setIssuer(cfg.cognito.emisor)
        .setAudience(cfg.cognito.clientId)
        .setIssuedAt()
        .setExpirationTime("1h")
        .sign(privateKey);
    },
    async cerrar() {
      await app.close();
      await pool.end();
    },
  };
}
