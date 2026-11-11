// Traducción de errores de conexión a la base (no requiere base de pruebas).
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { desdePostgres } from "../src/errores.js";
import { origenDe } from "../src/app.js";
import type { FastifyRequest } from "fastify";

describe("errores de conexión", () => {
  it("un tiempo de espera al conectar es 503, no un error interno", () => {
    for (const m of [
      "Connection terminated due to connection timeout",
      "timeout exceeded when trying to connect",
      "connect ECONNREFUSED 10.0.0.1:5432",
    ]) {
      const e = desdePostgres(new Error(m));
      assert.equal(e?.status, 503, m);
      assert.equal(e?.codigo, "base_no_disponible");
    }
  });

  it("otros errores sin código siguen sin traducirse", () => {
    assert.equal(desdePostgres(new Error("otra cosa")), null);
  });
});

describe("origen de la solicitud para la bitácora", () => {
  const req = (headers: Record<string, string>, remoto = "127.0.0.1") =>
    ({ headers, socket: { remoteAddress: remoto } }) as unknown as FastifyRequest;

  it("toma la IP de CloudFront, sin el puerto, y no la de X-Forwarded-For", () => {
    const o = origenDe(req({ "cloudfront-viewer-address": "203.0.113.7:51234", "x-forwarded-for": "1.2.3.4", "user-agent": "Mozilla/5.0" }));
    assert.deepEqual(o, { ip: "203.0.113.7", navegador: "Mozilla/5.0" });
  });

  it("acepta IPv6 y descarta valores que no son una IP", () => {
    assert.equal(origenDe(req({ "cloudfront-viewer-address": "2001:db8::1:443" })).ip, "2001:db8::1");
    assert.equal(origenDe(req({ "cloudfront-viewer-address": "no-es-ip:80" })).ip, null);
  });

  it("sin CloudFront usa la conexión; el navegador se recorta a 300 caracteres", () => {
    const o = origenDe(req({ "user-agent": "x".repeat(400) }, "::ffff:10.0.0.5"));
    assert.equal(o.ip, "10.0.0.5");
    assert.equal(o.navegador!.length, 300);
  });
});
