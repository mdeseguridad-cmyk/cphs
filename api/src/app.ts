// Construcción de la aplicación Fastify. La misma imagen corre en dos modos:
//   api        rutas /api/* (detrás de CloudFront) y /interno/eventos
//              (programación diaria e importaciones desde S3).
//   trabajos   /interno/trabajos: correos, usuarios de Cognito y consulta de
//              servicios de clientes. Sin acceso a la base.

import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from "fastify";
import type pg from "pg";
import type { Config } from "./config.js";
import { cargarSesion, resolverUsuario, tokenDeSolicitud, type Sesion, type VerificarToken } from "./auth.js";
import { enTransaccion, type Cliente } from "./db.js";
import { ErrorApi, desdePostgres, noAutenticado } from "./errores.js";
import type { Servicios } from "./servicios.js";
import { rutasOrganizacion } from "./rutas/organizacion.js";
import { rutasComites } from "./rutas/comites.js";
import { rutasPrograma } from "./rutas/programa.js";
import { rutasReuniones } from "./rutas/reuniones.js";
import { rutasDocumentos } from "./rutas/documentos.js";
import { rutasUsuarios } from "./rutas/usuarios.js";
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

export function construirApp(o: Opciones): FastifyInstance {
  const app = Fastify({
    logger: o.registro === false ? false : { level: "info", redact: ["req.headers.authorization", 'req.headers["x-token-usuario"]'] },
    bodyLimit: 1024 * 1024,
    trustProxy: true,
  });

  app.setErrorHandler((e, req, rep) => {
    const api = e instanceof ErrorApi ? e : desdePostgres(e);
    if (api) {
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
      return enTransaccion(o.pool, id, async (c) => fn(c, await cargarSesion(c, id)));
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
  rutasEventos(app, ctx);
  return app;
}
