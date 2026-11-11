// Conexión a PostgreSQL. La aplicación entra como paritario_app, que no es
// dueño de las tablas: la seguridad por fila aplica en cada consulta. Cada
// solicitud corre en una transacción que fija el usuario con SET LOCAL.

import { readFileSync } from "node:fs";
import pg from "pg";
import { Signer } from "@aws-sdk/rds-signer";
import type { Config } from "./config.js";

export type Cliente = pg.PoolClient;

// bigint (ids) como número: los ids del sistema caben holgadamente.
pg.types.setTypeParser(20, (v) => Number(v));
// bigint[] (listas de ids) como números.
const fijarParser = pg.types.setTypeParser as (oid: number, fn: (v: string) => unknown) => void;
fijarParser(1016, (v) =>
  v === "{}" ? [] : v.slice(1, -1).split(",").map((x) => (x === "NULL" ? null : Number(x))),
);
// date como texto AAAA-MM-DD, sin conversión a zona horaria.
pg.types.setTypeParser(1082, (v) => v);

export function crearPool(cfg: Config): pg.Pool {
  const { db } = cfg;
  let ssl: pg.PoolConfig["ssl"] = false;
  if (db.sslmode === "require") ssl = { rejectUnauthorized: false };
  if (db.sslmode === "verify-full") ssl = { rejectUnauthorized: true, ca: readFileSync(db.caPath, "utf8") };

  let password: pg.PoolConfig["password"] = db.clave;
  if (db.auth === "iam") {
    const signer = new Signer({ hostname: db.host, port: db.puerto, username: db.usuario, region: cfg.region });
    // El token dura 15 minutos y se genera localmente, sin llamar a AWS.
    password = () => signer.getAuthToken();
  }

  return new pg.Pool({
    host: db.host,
    port: db.puerto,
    database: db.nombre,
    user: db.usuario,
    password,
    ssl,
    max: db.maxConexiones,
    idleTimeoutMillis: 60_000,
    // Bajo el tiempo máximo de la función (29 s): la validación del token de
    // IAM en RDS puede tardar más de 10 s al abrir una conexión nueva.
    connectionTimeoutMillis: db.tiempoConexionMs,
    // Reconectar antes de que venza el token de IAM.
    maxLifetimeSeconds: 600,
  });
}

/** Ejecuta fn en una transacción, con el usuario fijado para la seguridad por fila. */
export async function enTransaccion<T>(pool: pg.Pool, usuarioId: number | null, fn: (c: Cliente) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query("BEGIN");
    await c.query("SET LOCAL search_path = paritario, public");
    if (usuarioId !== null) {
      await c.query("SELECT set_config('app.usuario_id', $1, true)", [String(usuarioId)]);
    }
    const r = await fn(c);
    await c.query("COMMIT");
    return r;
  } catch (e) {
    await c.query("ROLLBACK").catch(() => undefined);
    throw e;
  } finally {
    c.release();
  }
}

const IDENT = /^[a-z_][a-z0-9_]*$/;

/**
 * Inserta y devuelve el id. No usa RETURNING: con seguridad por fila, la fila
 * recién creada puede no ser legible en la misma sentencia; currval entrega
 * el id generado en esta sesión.
 */
export async function insertar(c: Cliente, tabla: string, valores: Record<string, unknown>): Promise<number> {
  const cols = Object.keys(valores).filter((k) => valores[k] !== undefined);
  for (const k of [tabla, ...cols]) if (!IDENT.test(k)) throw new Error(`Identificador inválido: ${k}`);
  const params = cols.map((_, i) => `$${i + 1}`);
  await c.query(`INSERT INTO ${tabla} (${cols.join(", ")}) VALUES (${params.join(", ")})`, cols.map((k) => valores[k]));
  const r = await c.query<{ id: number }>(`SELECT currval(pg_get_serial_sequence('paritario.${tabla}', 'id')) AS id`);
  return Number(r.rows[0]!.id);
}

/** UPDATE solo de las columnas presentes. Devuelve la cantidad de filas actualizadas. */
export async function actualizar(c: Cliente, tabla: string, id: number, valores: Record<string, unknown>): Promise<number> {
  const cols = Object.keys(valores).filter((k) => valores[k] !== undefined);
  if (cols.length === 0) return 1;
  for (const k of [tabla, ...cols]) if (!IDENT.test(k)) throw new Error(`Identificador inválido: ${k}`);
  const sets = cols.map((k, i) => `${k} = $${i + 2}`);
  const r = await c.query(`UPDATE ${tabla} SET ${sets.join(", ")} WHERE id = $1`, [id, ...cols.map((k) => valores[k])]);
  return r.rowCount ?? 0;
}

export async function uno<T extends pg.QueryResultRow>(c: Cliente, sql: string, params: unknown[] = []): Promise<T | null> {
  const r = await c.query<T>(sql, params);
  return r.rows[0] ?? null;
}

export async function varios<T extends pg.QueryResultRow>(c: Cliente, sql: string, params: unknown[] = []): Promise<T[]> {
  const r = await c.query<T>(sql, params);
  return r.rows;
}

/**
 * Bitácora de accesos a datos personales (Ley 21.719). Cada entrada lleva la
 * empresa del comité: así solo su administrador la consulta (seguridad por
 * fila en log_acceso).
 */
export async function bitacora(
  c: Cliente,
  usuarioId: number,
  accion: "ver" | "crear" | "editar" | "eliminar" | "exportar",
  entidad: string,
  entidadId: number,
  comiteId: number,
): Promise<void> {
  await c.query(
    `INSERT INTO log_acceso (usuario_id, empresa_id, accion, entidad, entidad_id)
     VALUES ($1, (SELECT empresa_id FROM comite WHERE id = $5), $2, $3, $4)`,
    [usuarioId, accion, entidad, entidadId, comiteId],
  );
}
