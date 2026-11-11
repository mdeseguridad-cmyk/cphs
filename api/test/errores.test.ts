// Traducción de errores de conexión a la base (no requiere base de pruebas).
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { desdePostgres } from "../src/errores.js";

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
