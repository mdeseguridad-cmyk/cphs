// Construcción de la aplicación Fastify. La misma imagen corre en dos modos:
//   api        rutas /api/* (detrás de CloudFront) y /interno/eventos
//              (programación diaria e importaciones desde S3).
//   trabajos   /interno/trabajos: correos, usuarios de Cognito y consulta de
//              servicios de clientes. Sin acceso a la base.

import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from "fastify";
import { isIP } from "node:net";
import type pg from "pg";
import type { Config } from "./config.js";
import { cargarSesion, resolverUsuario, tokenDeSolicitud, type Sesion, type VerificarToken } from "./auth.js";
import { enTransaccion, type Cliente, type Origen } from "./db.js";
import { ErrorApi, desdePostgres, noAutenticado } from "./errores.js";
import type { Servicios } from "./servicios.js";
import { rutasOrganizacion } from "./rutas/organizacion.js";
import { rutasComites } from "./rutas/comites.js";
import { rutasPrograma } from "./rutas/programa.js";
import { rutasReuniones } from "./rutas/reuniones.js";
import { rutasDocumentos } from "./rutas/documentos.js";
import { rutasUsuarios } from "./rutas/usuarios.js";
import { rutasBitacora } from "./rutas/bitacora.js";
import { rutasEventos } from "./interno/eventos.js";
import { rutasTrabajos } from "./interno/trabajos.js";

export interface Contexto {
  cfg: Config;
  pool: pg.Pool;
  servicios: Servicios;
  /** Ejecuta fn en una transacción con la sesión del usuario autenticado. */
  tx<T>(req: FastifyRequest, fn: (c: Cliente, s: Sesion) => Promise<T>): Promise<T>;
}

declare module "fastify" {
  interface FastifyRequest {
    usuarioId?: number;
  }
}

export interface Opciones {
  cfg: Config;
  pool: pg.Pool;
  servicios: Servicios;
  verificarToken: VerificarToken;
  registro?: boolean;
}

/**
 * IP y navegador de quien hace la solicitud, para la bitácora. En AWS la IP
 * sale de CloudFront-Viewer-Address, que pone CloudFront y el visitante no
 * puede falsificar: la función solo acepta llamadas firmadas por CloudFront.
 * X-Forwarded-For no sirve, porque su primer valor lo puede escribir el
 * visitante. Sin CloudFront (desarrollo y pruebas), la IP de la conexión.
 */
export function origenDe(req: FastifyRequest): Origen {
  // En Lambda la conexión viene del adaptador local (127.0.0.1): no sirve.
  let ip: string | null = process.env.AWS_LAMBDA_FUNCTION_NAME ? null : (req.socket.remoteAddress ?? null);
  const visor = req.headers["cloudfront-viewer-address"];
  if (typeof visor === "string" && visor) {
    // "198.51.100.10:46532" o "2001:db8::1:46532": la IP, sin el puerto final.
    ip = visor.slice(0, visor.lastIndexOf(":")).replace(/^\[|\]$/g, "");
  }
  if (ip?.startsWith("::ffff:")) ip = ip.slice(7);
  const ua = req.headers["user-agent"];
  return {
    ip: ip && isIP(ip) ? ip : null,
    navegador: typeof ua === "string" && ua ? ua.slice(0, 300) : null,
  };
}

export function construirApp(o: Opciones): FastifyInstance {
  const app = Fastify({
    logger: o.registro === false ? false : { level: "info", redact: ["req.headers.authorization", 'req.headers["x-token-usuario"]'] },
    bodyLimit: 1024 * 1024,
    trustProxy: true,
  });

  app.setErrorHandler((e, req, rep) => {
    const api = e instanceof ErrorApi ? e : desdePostgres(e);
    if (api) {
      if (api.status >= 500) req.log.error(e);
      return rep.status(api.status).send({ error: api.codigo, mensaje: api.message, detalle: api.detalle });
    }
    const fe = e as { statusCode?: number; validation?: unknown };
    if (fe.statusCode && fe.statusCode < 500) {
      return rep.status(fe.statusCode).send({ error: "solicitud_invalida", mensaje: e.message });
    }
    req.log.error(e);
    return rep.status(500).send({ error: "interno", mensaje: "Error interno" });
  });

  app.setNotFoundHandler((_req, rep) => rep.status(404).send({ error: "no_encontrado", mensaje: "Ruta inexistente" }));

  const ctx: Contexto = {
    cfg: o.cfg,
    pool: o.pool,
    servicios: o.servicios,
    async tx(req, fn) {
      if (req.usuarioId === undefined) throw noAutenticado();
      const id = req.usuarioId;
      return enTransaccion(o.pool, id, async (c) => fn(c, await cargarSesion(c, id)), origenDe(req));
    },
  };

  // Salud: Lambda Web Adapter la consulta al arrancar. No toca la base, que
  // puede estar apagada fuera del horario.
  app.get("/api/salud", async () => ({ estado: "ok", modo: o.cfg.modo }));

  if (o.cfg.modo === "trabajos") {
    rutasTrabajos(app, ctx);
    return app;
  }

  app.addHook("preHandler", async (req: FastifyRequest, _rep: FastifyReply) => {
    if (!req.url.startsWith("/api/") || req.url === "/api/salud") return;
    const token = tokenDeSolicitud(req.headers);
    if (!token) throw noAutenticado();
    const reclamos = await o.verificarToken(token);
    req.usuarioId = await resolverUsuario(o.pool, reclamos);
  });

  rutasOrganizacion(app, ctx);
  rutasComites(app, ctx);
  rutasPrograma(app, ctx);
  rutasReuniones(app, ctx);
  rutasDocumentos(app, ctx);
  rutasUsuarios(app, ctx);
  rutasBitacora(app, ctx);
  rutasEventos(app, ctx);
  return app;
}
