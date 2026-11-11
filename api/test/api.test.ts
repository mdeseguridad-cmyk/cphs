// Pruebas de la API contra PostgreSQL real, con la seguridad por fila activa.
// Requieren una base de pruebas (ver test/entorno.ts); si no hay, se omiten.

import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { baseDisponible, crearPrueba, prepararBase, sqlAdmin, type Prueba } from "./entorno.js";

const hay = await baseDisponible();
const SUB = {
  admin1: "00000000-0000-0000-0000-0000000000a1",
  coord: "00000000-0000-0000-0000-0000000000a2",
  auditor: "00000000-0000-0000-0000-0000000000a3",
  admin3: "00000000-0000-0000-0000-0000000000a4",
  org: "00000000-0000-0000-0000-0000000000a5",
  doble: "00000000-0000-0000-0000-0000000000a6",
  sso: "00000000-0000-0000-0000-0000000000b1",
};

describe("API de Paritario", { skip: hay ? false : "sin base de pruebas (PGTEST_*)" }, () => {
  let p: Prueba;
  const tokens: Record<string, string> = {};

  async function llamar(metodo: string, url: string, quien?: string, cuerpo?: unknown) {
    const r = await p.app.inject({
      method: metodo as "GET",
      url,
      headers: quien ? { "x-token-usuario": tokens[quien] ?? quien } : {},
      payload: cuerpo as object | undefined,
    });
    return { status: r.statusCode, json: r.body ? (JSON.parse(r.body) as Record<string, any>) : {} };
  }

  const comiteId = async (nombre: string) => (await sqlAdmin<{ id: number }>("SELECT id FROM comite WHERE nombre = $1", [nombre]))[0]!.id;
  const empresaId = async (nombre: string) => (await sqlAdmin<{ id: number }>("SELECT id FROM empresa WHERE razon_social = $1", [nombre]))[0]!.id;

  before(async () => {
    prepararBase();
    p = await crearPrueba();
    tokens.admin1 = await p.token({ sub: SUB.admin1, usuario: "15151515-0" });
    tokens.coord = await p.token({ sub: SUB.coord, usuario: "16161616-8" });
    tokens.auditor = await p.token({ sub: SUB.auditor, usuario: "12345678-5" });
    tokens.admin3 = await p.token({ sub: SUB.admin3, usuario: "17171717-5" });
    tokens.org = await p.token({ sub: SUB.org, usuario: "14141414-3" });
    tokens.doble = await p.token({ sub: SUB.doble, usuario: "13131313-6" });
  });

  after(async () => {
    await p?.cerrar();
  });

  describe("autenticación", () => {
    it("la salud responde sin token ni base", async () => {
      assert.equal((await llamar("GET", "/api/salud")).status, 200);
    });

    it("sin token o con un token inválido responde 401", async () => {
      assert.equal((await llamar("GET", "/api/yo")).status, 401);
      assert.equal((await llamar("GET", "/api/yo", "no-es-un-token")).status, 401);
    });

    it("un token de otro emisor se rechaza", async () => {
      const otro = await crearPrueba();
      const t = await otro.token({ sub: SUB.admin1, usuario: "15151515-0" });
      await otro.cerrar();
      assert.equal((await llamar("GET", "/api/yo", t)).status, 401);
    });

    it("el primer ingreso de un invitado une su cuenta y lo deja activo", async () => {
      const r = await llamar("GET", "/api/yo", "coord");
      assert.equal(r.status, 200);
      assert.equal(r.json.estado, "activo");
      assert.equal(r.json.roles[0].rol, "COORDINADOR");
      const [u] = await sqlAdmin<{ cognito_sub: string }>("SELECT cognito_sub FROM usuario WHERE rut = '16161616-8'");
      assert.equal(u!.cognito_sub, SUB.coord);
    });

    it("el primer ingreso con solicitudes simultáneas no falla", async () => {
      await sqlAdmin("INSERT INTO persona (rut, nombres, apellidos) VALUES ('23232323-K', 'Simul', 'Tanea')");
      await sqlAdmin(
        `INSERT INTO usuario (rut, persona_id) SELECT rut, id FROM persona WHERE rut = '23232323-K';
         INSERT INTO usuario_rol (usuario_id, rol_id, empresa_id)
         SELECT u.id, r.id, e.id FROM usuario u, rol r, empresa e
          WHERE u.rut = '23232323-K' AND r.codigo = 'AUDITOR' AND e.razon_social = 'Empresa 3'`,
      );
      const t = await p.token({ sub: "00000000-0000-0000-0000-0000000000c1", usuario: "23232323-K" });
      const r = await Promise.all([llamar("GET", "/api/yo", t), llamar("GET", "/api/empresas", t), llamar("GET", "/api/comites", t)]);
      assert.deepEqual(r.map((x) => x.status), [200, 200, 200]);
    });

    it("una cuenta de Cognito sin usuario en Paritario no entra", async () => {
      const t = await p.token({ sub: "00000000-0000-0000-0000-0000000000ff", usuario: "11111111-1" });
      assert.equal((await llamar("GET", "/api/yo", t)).status, 403);
    });

    it("el SSO del organismo crea el usuario con el rol y las empresas de sus contratos", async () => {
      const t = await p.token({ sub: SUB.sso, proveedor: "mutual-a", rut: "19.191.919-k", rol: "PREV", contratos: "A-1, A-2" });
      const r = await llamar("GET", "/api/yo", t);
      assert.equal(r.status, 200);
      assert.deepEqual(r.json.roles.map((x: { empresa: string }) => x.empresa).sort(), ["Empresa 1", "Empresa 2"]);
      assert.ok(r.json.roles.every((x: { rol: string; origen: string }) => x.rol === "COORDINADOR" && x.origen === "sso"));
    });
  });

  describe("aislamiento y permisos", () => {
    it("cada usuario ve solo los comités de su ámbito", async () => {
      assert.deepEqual((await llamar("GET", "/api/comites", "admin1")).json.map((c: { nombre: string }) => c.nombre), ["C1"]);
      assert.deepEqual((await llamar("GET", "/api/comites", "admin3")).json.map((c: { nombre: string }) => c.nombre), ["C3"]);
      assert.equal((await llamar("GET", `/api/comites/${await comiteId("C1")}`, "admin3")).status, 404);
    });

    it("el organismo ve los comités de sus empresas pero no sus integrantes", async () => {
      const c1 = await comiteId("C1");
      assert.equal((await llamar("GET", `/api/comites/${c1}`, "org")).status, 200);
      const i = await llamar("GET", `/api/comites/${c1}/integrantes`, "org");
      assert.equal(i.status, 200);
      assert.deepEqual(i.json, []);
      assert.equal((await llamar("GET", "/api/comites", "org")).json.some((c: { nombre: string }) => c.nombre === "C3"), false);
    });

    it("solo el administrador crea comités en su empresa", async () => {
      const e1 = await empresaId("Empresa 1");
      assert.equal((await llamar("POST", "/api/comites", "coord", { empresa_id: e1, nombre: "C9" })).status, 403);
      assert.equal((await llamar("POST", "/api/comites", "admin3", { empresa_id: e1, nombre: "C9" })).status, 403);
      const r = await llamar("POST", "/api/comites", "admin1", { empresa_id: e1, nombre: "C2" });
      assert.equal(r.status, 201);
      assert.ok(r.json.id > 0);
    });

    it("el auditor solo lee", async () => {
      const c1 = await comiteId("C1");
      assert.equal((await llamar("GET", `/api/comites/${c1}`, "auditor")).status, 200);
      assert.equal((await llamar("PATCH", `/api/comites/${c1}`, "auditor", { nombre: "X" })).status, 403);
    });

    it("el coordinador de C1 no edita otro comité de la empresa", async () => {
      const c2 = await comiteId("C2");
      // No lo ve (seguridad por fila): responde 404, sin revelar que existe.
      assert.equal((await llamar("PATCH", `/api/comites/${c2}`, "coord", { nombre: "X" })).status, 404);
    });

    it("datos inválidos responden 422 con el detalle", async () => {
      const r = await llamar("POST", "/api/comites", "admin1", { nombre: "" });
      assert.equal(r.status, 422);
      assert.ok(Array.isArray(r.json.detalle));
    });
  });

  describe("integrantes y comisiones", () => {
    it("agrega integrantes y aplica las reglas del DS 44", async () => {
      const c1 = await comiteId("C1");
      const base = { nombres: "Ana", apellidos: "Uno", tipo: "titular", representacion: "trabajadores" };
      const a = await llamar("POST", `/api/comites/${c1}/integrantes`, "coord", { ...base, rut: "11.111.111-1", cargo: "presidente" });
      assert.equal(a.status, 201);
      const b = await llamar("POST", `/api/comites/${c1}/integrantes`, "coord", { ...base, rut: "22222222-2", nombres: "Beto", cargo: "presidente" });
      assert.equal(b.status, 422, "un segundo presidente vigente se rechaza");
      const aforado = await llamar("POST", `/api/comites/${c1}/integrantes`, "coord", {
        ...base, rut: "22222222-2", nombres: "Beto", tipo: "suplente", es_aforado: true,
      });
      assert.equal(aforado.status, 422, "el aforado debe ser titular de los trabajadores");
      const lista = await llamar("GET", `/api/comites/${c1}/integrantes`, "admin1");
      assert.equal(lista.json.length, 1);
      assert.equal(lista.json[0].rut, "11111111-1");
    });

    it("una persona que ya existe en otra empresa se reutiliza sin ver ni cambiar sus datos", async () => {
      const c3 = await comiteId("C3");
      const r = await llamar("POST", `/api/comites/${c3}/integrantes`, "admin3", {
        rut: "11111111-1", nombres: "Otro", apellidos: "Nombre", tipo: "titular", representacion: "empresa",
      });
      assert.equal(r.status, 201);
      const [persona] = await sqlAdmin<{ nombres: string }>("SELECT nombres FROM persona WHERE rut = '11111111-1'");
      assert.equal(persona!.nombres, "Ana");
    });

    it("una comisión solo admite integrantes vigentes del comité", async () => {
      const c1 = await comiteId("C1");
      const com = await llamar("POST", `/api/comites/${c1}/comisiones`, "coord", { tipo: "capacitacion_difusion" });
      assert.equal(com.status, 201);
      const [ana] = await sqlAdmin<{ id: number }>("SELECT ci.id FROM comite_integrante ci JOIN comite c ON c.id = ci.comite_id WHERE c.nombre = 'C1'");
      const [ajeno] = await sqlAdmin<{ id: number }>("SELECT ci.id FROM comite_integrante ci JOIN comite c ON c.id = ci.comite_id WHERE c.nombre = 'C3'");
      assert.equal((await llamar("PUT", `/api/comisiones/${com.json.id}/integrantes`, "coord", { integrantes: [ajeno!.id] })).status, 422);
      assert.equal((await llamar("PUT", `/api/comisiones/${com.json.id}/integrantes`, "coord", { integrantes: [ana!.id] })).status, 200);
      const lista = await llamar("GET", `/api/comites/${c1}/comisiones`, "coord");
      assert.deepEqual(lista.json[0].integrantes, [ana!.id]);
    });

    it("el término de un integrante conserva el historial", async () => {
      const c3 = await comiteId("C3");
      const [i] = await sqlAdmin<{ id: number }>("SELECT ci.id FROM comite_integrante ci WHERE ci.comite_id = $1", [c3]);
      assert.equal((await llamar("POST", `/api/integrantes/${i!.id}/termino`, "admin3", { fecha_termino: "2026-12-31" })).status, 200);
      const lista = await llamar("GET", `/api/comites/${c3}/integrantes`, "admin3");
      assert.equal(lista.json[0].vigente, false);
    });

    it("ver integrantes queda en la bitácora, con la empresa del comité", async () => {
      const filas = await sqlAdmin<{ empresa: string }>(
        "SELECT e.razon_social AS empresa FROM log_acceso l JOIN empresa e ON e.id = l.empresa_id WHERE l.entidad = 'comite' AND l.accion = 'ver'",
      );
      assert.ok(filas.length >= 1);
      const [sinEmpresa] = await sqlAdmin<{ n: number }>("SELECT count(*)::int AS n FROM log_acceso WHERE empresa_id IS NULL");
      assert.equal(sinEmpresa!.n, 0, "toda entrada de la API lleva su empresa");
    });

    it("cada administrador ve en la bitácora solo los accesos a su empresa", async () => {
      const [e1] = await sqlAdmin<{ id: number }>("SELECT id FROM empresa WHERE razon_social = 'Empresa 1'");
      const [admin1] = await sqlAdmin<{ id: number }>("SELECT id FROM usuario WHERE rut = '15151515-0'");
      const visibles = async (usuarioId: number) =>
        p.pool.connect().then(async (c) => {
          try {
            await c.query("BEGIN");
            await c.query("SELECT set_config('app.usuario_id', $1, true)", [String(usuarioId)]);
            const r = await c.query<{ empresa_id: number }>("SELECT DISTINCT empresa_id FROM paritario.log_acceso");
            await c.query("ROLLBACK");
            return r.rows.map((x) => x.empresa_id);
          } finally {
            c.release();
          }
        });
      assert.deepEqual(await visibles(admin1!.id), [e1!.id]);
      const [coord] = await sqlAdmin<{ id: number }>("SELECT id FROM usuario WHERE rut = '16161616-8'");
      assert.deepEqual(await visibles(coord!.id), [], "un coordinador no consulta la bitácora");
    });

    it("el administrador consulta la bitácora con lo que se vio o cambió, filtrada y paginada", async () => {
      const e1 = await empresaId("Empresa 1");
      const r = await llamar("GET", `/api/empresas/${e1}/bitacora`, "admin1");
      assert.equal(r.status, 200);
      const entradas = r.json.entradas as Record<string, any>[];
      assert.ok(entradas.length >= 2);
      const alta = entradas.find((e) => e.accion === "crear" && e.entidad === "comite_integrante");
      assert.ok(alta, "el alta de un integrante aparece");
      assert.equal(alta!.comite, "C1");
      assert.ok(alta!.detalle, "describe a la persona afectada");
      assert.ok(alta!.rut, "identifica a quien lo hizo");

      const soloCrear = await llamar("GET", `/api/empresas/${e1}/bitacora?accion=crear`, "admin1");
      assert.ok(soloCrear.json.entradas.every((e: any) => e.accion === "crear"));
      const futuro = await llamar("GET", `/api/empresas/${e1}/bitacora?desde=2099-01-01`, "admin1");
      assert.equal(futuro.json.entradas.length, 0);
      assert.equal((await llamar("GET", `/api/empresas/${e1}/bitacora?desde=2025-02-01&hasta=2025-01-01`, "admin1")).status, 422);

      const pag1 = await llamar("GET", `/api/empresas/${e1}/bitacora?limite=1`, "admin1");
      assert.equal(pag1.json.entradas.length, 1);
      assert.equal(pag1.json.siguiente, pag1.json.entradas[0].id);
      const pag2 = await llamar("GET", `/api/empresas/${e1}/bitacora?limite=1&antes=${pag1.json.siguiente}`, "admin1");
      assert.ok(pag2.json.entradas[0].id < pag1.json.siguiente);
    });

    it("solo el administrador de esa empresa consulta su bitácora", async () => {
      const e1 = await empresaId("Empresa 1");
      assert.equal((await llamar("GET", `/api/empresas/${e1}/bitacora`, "coord")).status, 403);
      assert.equal((await llamar("GET", `/api/empresas/${e1}/bitacora`, "auditor")).status, 403);
      assert.equal((await llamar("GET", `/api/empresas/${e1}/bitacora`, "admin3")).status, 403);
      assert.equal((await llamar("GET", `/api/empresas/${e1}/bitacora.csv`, "admin3")).status, 403);
    });

    it("cada entrada guarda la IP y el navegador de quien accedió", async () => {
      const c1 = await comiteId("C1");
      const r = await p.app.inject({
        method: "GET",
        url: `/api/comites/${c1}/integrantes`,
        headers: { "x-token-usuario": tokens.admin1!, "cloudfront-viewer-address": "203.0.113.7:51234", "user-agent": "Navegador de prueba/1.0" },
      });
      assert.equal(r.statusCode, 200);
      const [fila] = await sqlAdmin<{ ip: string; user_agent: string }>(
        "SELECT host(ip) AS ip, user_agent FROM log_acceso WHERE entidad = 'comite' AND entidad_id = $1 ORDER BY id DESC LIMIT 1",
        [c1],
      );
      assert.deepEqual(fila, { ip: "203.0.113.7", user_agent: "Navegador de prueba/1.0" });
      const e1 = await empresaId("Empresa 1");
      const b = await llamar("GET", `/api/empresas/${e1}/bitacora?limite=1`, "admin1");
      assert.equal(b.json.entradas[0].ip, "203.0.113.7");
      assert.equal(b.json.entradas[0].navegador, "Navegador de prueba/1.0");
    });

    it("descargar la bitácora entrega un CSV y queda registrado", async () => {
      const e1 = await empresaId("Empresa 1");
      const r = await p.app.inject({ method: "GET", url: `/api/empresas/${e1}/bitacora.csv`, headers: { "x-token-usuario": tokens.admin1! } });
      assert.equal(r.statusCode, 200);
      assert.match(r.headers["content-type"] as string, /^text\/csv/);
      const lineas = r.body.replace(/^\uFEFF/, "").trim().split("\r\n");
      assert.match(lineas[0]!, /^Fecha \(hora de Chile\);RUT;Persona;Acción;Sobre;Detalle;Comité;IP;Navegador$/);
      assert.ok(lineas.length >= 3);
      const [n] = await sqlAdmin<{ n: number }>(
        "SELECT count(*)::int AS n FROM log_acceso WHERE accion = 'exportar' AND entidad = 'log_acceso' AND empresa_id = $1",
        [e1],
      );
      assert.equal(n!.n, 1);
      const usuarios = await llamar("GET", `/api/empresas/${e1}/bitacora/usuarios`, "admin1");
      assert.ok((usuarios.json as unknown as any[]).some((u) => u.rut === "15151515-0"));
    });
  });

  describe("programa de trabajo", () => {
    it("instancia el programa desde la plantilla del rubro y asigna comisiones", async () => {
      const c1 = await comiteId("C1");
      const pl = await llamar("GET", "/api/plantillas?seccion=F", "coord");
      assert.equal(pl.json.length, 1);
      const r = await llamar("POST", `/api/comites/${c1}/programa`, "coord", { plantilla_id: pl.json[0].id, anio: 2026 });
      assert.equal(r.status, 201);
      assert.equal(r.json.creadas, 3);
      assert.equal((await llamar("POST", `/api/comites/${c1}/programa`, "coord", { plantilla_id: pl.json[0].id })).status, 409);
      const acts = await llamar("GET", `/api/comites/${c1}/actividades`, "coord");
      const charla = acts.json.find((a: { titulo: string }) => a.titulo.startsWith("Charla"));
      assert.ok(charla.comision_id, "la charla queda en la comisión de capacitación");
    });

    it("cerrar una actividad fija su fecha de cierre y reabrirla la quita", async () => {
      const c1 = await comiteId("C1");
      const acts = await llamar("GET", `/api/comites/${c1}/actividades`, "coord");
      const a = acts.json[0];
      assert.equal((await llamar("PATCH", `/api/actividades/${a.id}`, "coord", { estado: "cerrado" })).status, 200);
      let [fila] = await sqlAdmin<{ fecha_cierre: string | null }>("SELECT fecha_cierre FROM actividad WHERE id = $1", [a.id]);
      assert.ok(fila!.fecha_cierre);
      assert.equal((await llamar("PATCH", `/api/actividades/${a.id}`, "coord", { estado: "en_ejecucion" })).status, 200);
      [fila] = await sqlAdmin<{ fecha_cierre: string | null }>("SELECT fecha_cierre FROM actividad WHERE id = $1", [a.id]);
      assert.equal(fila!.fecha_cierre, null);
    });

    it("el responsable debe ser integrante del comité", async () => {
      const c1 = await comiteId("C1");
      const [ajeno] = await sqlAdmin<{ id: number }>("SELECT ci.id FROM comite_integrante ci JOIN comite c ON c.id = ci.comite_id WHERE c.nombre = 'C3'");
      const r = await llamar("POST", `/api/comites/${c1}/actividades`, "coord", { titulo: "Simulacro", responsable_integrante_id: ajeno!.id });
      assert.equal(r.status, 422);
    });
  });

  describe("reuniones, actas e indicadores", () => {
    let actaId = 0;

    it("crea el cronograma de 12 reuniones sin duplicar meses", async () => {
      const c1 = await comiteId("C1");
      await llamar("POST", `/api/comites/${c1}/reuniones`, "coord", { anio: 2026, mes: 1 });
      const r = await llamar("POST", `/api/comites/${c1}/cronograma`, "coord", { anio: 2026 });
      assert.equal(r.json.creadas, 11);
      assert.equal((await llamar("GET", `/api/comites/${c1}/reuniones?anio=2026`, "coord")).json.length, 12);
    });

    it("el cronograma parte en el mes de constitución del comité", async () => {
      const e1 = await empresaId("Empresa 1");
      const nuevo = await llamar("POST", "/api/comites", "admin1", { empresa_id: e1, nombre: "C-mayo", fecha_constitucion: "2026-05-11" });
      assert.equal((await llamar("POST", `/api/comites/${nuevo.json.id}/cronograma`, "admin1", { anio: 2026 })).json.creadas, 8);
      assert.equal((await llamar("POST", `/api/comites/${nuevo.json.id}/cronograma`, "admin1", { anio: 2025 })).json.creadas, 0);
    });

    it("sube el acta: registro pendiente, URL firmada y confirmación con la huella", async () => {
      const c1 = await comiteId("C1");
      const contenido = Buffer.from("%PDF-1.7 acta de prueba");
      const sha256 = createHash("sha256").update(contenido).digest("hex");
      const r = await llamar("POST", `/api/comites/${c1}/documentos`, "coord", {
        tipo: "reunion", nombre: "Acta enero 2026", mime: "application/pdf", tamano_bytes: contenido.length, sha256,
      });
      assert.equal(r.status, 201);
      assert.match(r.json.subida.url, /^https:\/\/s3\.prueba\/documentos\/comites\//);
      actaId = r.json.id;
      assert.equal((await llamar("POST", `/api/documentos/${actaId}/confirmar`, "coord")).status, 409, "aún no se sube");
      const clave = r.json.subida.url.replace("https://s3.prueba/documentos/", "");
      p.servicios.almacen.subidos.set(`documentos/${clave}`, { tamano: contenido.length, sha256Base64: Buffer.from(sha256, "hex").toString("base64") });
      const conf = await llamar("POST", `/api/documentos/${actaId}/confirmar`, "coord");
      assert.equal(conf.json.estado, "disponible");
      const d = await llamar("GET", `/api/documentos/${actaId}/descarga`, "auditor");
      assert.equal(d.status, 200);
      assert.match(d.json.url, /descarga/);
    });

    it("un archivo distinto al declarado se rechaza", async () => {
      const c1 = await comiteId("C1");
      const sha256 = "a".repeat(64);
      const r = await llamar("POST", `/api/comites/${c1}/documentos`, "coord", {
        tipo: "otro", nombre: "Distinto", mime: "application/pdf", tamano_bytes: 10, sha256,
      });
      const clave = r.json.subida.url.replace("https://s3.prueba/documentos/", "");
      p.servicios.almacen.subidos.set(`documentos/${clave}`, { tamano: 10, sha256Base64: Buffer.from("b".repeat(64), "hex").toString("base64") });
      assert.equal((await llamar("POST", `/api/documentos/${r.json.id}/confirmar`, "coord")).status, 422);
    });

    it("una reunión realizada exige fecha y el acta debe estar disponible", async () => {
      const c1 = await comiteId("C1");
      const reuniones = await llamar("GET", `/api/comites/${c1}/reuniones?anio=2026`, "coord");
      const enero = reuniones.json.find((x: { mes: number }) => x.mes === 1);
      assert.equal((await llamar("PATCH", `/api/reuniones/${enero.id}`, "coord", { estado: "realizada" })).status, 422);
      const ok = await llamar("PATCH", `/api/reuniones/${enero.id}`, "coord", { estado: "realizada", fecha_realizada: "2026-01-15", acta_documento_id: actaId });
      assert.equal(ok.status, 200);
      const febrero = reuniones.json.find((x: { mes: number }) => x.mes === 2);
      assert.equal((await llamar("PATCH", `/api/reuniones/${febrero.id}`, "coord", { estado: "no_realizada" })).status, 200);
    });

    it("registra asistencia solo de integrantes del comité", async () => {
      const c1 = await comiteId("C1");
      const reuniones = await llamar("GET", `/api/comites/${c1}/reuniones?anio=2026`, "coord");
      const enero = reuniones.json.find((x: { mes: number }) => x.mes === 1);
      const integrantes = await llamar("GET", `/api/comites/${c1}/integrantes`, "coord");
      const r = await llamar("PUT", `/api/reuniones/${enero.id}/asistencia`, "coord", {
        asistencia: [{ integrante_id: integrantes.json[0].id, presente: true }],
      });
      assert.equal(r.status, 200);
      const [ajeno] = await sqlAdmin<{ id: number }>("SELECT ci.id FROM comite_integrante ci JOIN comite c ON c.id = ci.comite_id WHERE c.nombre = 'C3'");
      const mal = await llamar("PUT", `/api/reuniones/${enero.id}/asistencia`, "coord", { asistencia: [{ integrante_id: ajeno!.id, presente: true }] });
      assert.equal(mal.status, 422);
    });

    it("el cumplimiento cuenta como exigidos los meses ya terminados, aunque no se registren", async () => {
      const r = await llamar("GET", "/api/indicadores?anio=2026", "org");
      const c1 = r.json.find((x: { comite: string }) => x.comite === "C1");
      // Enero realizada, febrero no realizada; el resto, planificadas: cuentan las de meses ya terminados.
      const ahora = new Date();
      const terminados = ahora.getFullYear() > 2026 ? 12 : ahora.getMonth();
      const exigidas = Math.max(2, terminados);
      assert.equal(c1.reuniones_realizadas, 1);
      assert.equal(c1.reuniones_exigidas, exigidas);
      assert.equal(Number(c1.cumplimiento), Math.round(1000 / exigidas) / 10);
    });
  });

  describe("usuarios", () => {
    it("invitar crea el usuario invitado y deja el trabajo para Cognito", async () => {
      const e1 = await empresaId("Empresa 1");
      const r = await llamar("POST", `/api/empresas/${e1}/usuarios`, "admin1", {
        rut: "21.212.121-5", nombres: "Nueva", apellidos: "Persona", correo: "nueva@e1.cl", rol: "AUDITOR",
      });
      assert.equal(r.status, 201, JSON.stringify(r.json));
      assert.equal(r.json.invitacion_enviada, true);
      const trabajos = p.servicios.almacen.claves("trabajos/crear_usuario/");
      assert.equal(trabajos.length, 1);
      assert.deepEqual(JSON.parse(p.servicios.almacen.objetos.get(trabajos[0]!)!), { tipo: "crear_usuario", rut: "21212121-5", correo: "nueva@e1.cl" });
      assert.equal((await llamar("POST", `/api/empresas/${e1}/usuarios`, "admin1", {
        rut: "21212121-5", nombres: "Nueva", apellidos: "Persona", correo: "nueva@e1.cl", rol: "AUDITOR",
      })).status, 409);
    });

    it("el administrador ve los usuarios de su empresa con sus nombres", async () => {
      const e1 = await empresaId("Empresa 1");
      const r = await llamar("GET", `/api/empresas/${e1}/usuarios`, "admin1");
      const nueva = r.json.find((u: { rut: string }) => u.rut === "21212121-5");
      assert.equal(nueva.nombres, "Nueva");
      assert.equal(nueva.estado, "invitado");
      assert.equal((await llamar("GET", `/api/empresas/${e1}/usuarios`, "coord")).status, 403);
    });

    it("no se bloquea a quien tiene acceso a otra empresa; se le quita el acceso", async () => {
      const [doble] = await sqlAdmin<{ id: number }>("SELECT id FROM usuario WHERE rut = '13131313-6'");
      assert.equal((await llamar("POST", `/api/usuarios/${doble!.id}/bloquear`, "admin1")).status, 403);
      const [acceso] = await sqlAdmin<{ id: number }>(
        "SELECT ur.id FROM usuario_rol ur JOIN empresa e ON e.id = ur.empresa_id WHERE ur.usuario_id = $1 AND e.razon_social = 'Empresa 1'",
        [doble!.id],
      );
      assert.equal((await llamar("DELETE", `/api/accesos/${acceso!.id}`, "admin1")).status, 200);
      assert.equal((await llamar("GET", "/api/comites", "doble")).json.some((c: { nombre: string }) => c.nombre === "C1"), false);
    });

    it("un acceso entregado por el SSO no se quita a mano", async () => {
      const [a] = await sqlAdmin<{ id: number }>(
        "SELECT ur.id FROM usuario_rol ur JOIN empresa e ON e.id = ur.empresa_id WHERE ur.origen = 'sso' AND e.razon_social = 'Empresa 1'",
      );
      assert.equal((await llamar("DELETE", `/api/accesos/${a!.id}`, "admin1")).status, 409);
    });

    it("bloquear impide el ingreso de inmediato y deja el trabajo para Cognito", async () => {
      const [aud] = await sqlAdmin<{ id: number }>("SELECT id FROM usuario WHERE rut = '12345678-5'");
      assert.equal((await llamar("GET", "/api/yo", "auditor")).status, 200);
      assert.equal((await llamar("POST", `/api/usuarios/${aud!.id}/bloquear`, "admin1")).status, 200);
      assert.equal((await llamar("GET", "/api/yo", "auditor")).status, 401);
      assert.equal(p.servicios.almacen.claves("trabajos/bloquear/").length, 1);
      assert.equal((await llamar("POST", `/api/usuarios/${aud!.id}/desbloquear`, "admin1")).json.estado, "activo");
    });
  });

  describe("centros de trabajo", () => {
    it("un centro sincronizado solo cambia su alias", async () => {
      const e1 = await empresaId("Empresa 1");
      const nuevo = await llamar("POST", `/api/empresas/${e1}/centros`, "admin1", { nombre: "Bodega", comuna_id: 13101 });
      assert.equal(nuevo.status, 201);
      await sqlAdmin("UPDATE sucursal SET codigo_externo = 'CT-9' WHERE id = $1", [nuevo.json.id]);
      assert.equal((await llamar("PATCH", `/api/centros/${nuevo.json.id}`, "admin1", { nombre: "Otra" })).status, 409);
      assert.equal((await llamar("PATCH", `/api/centros/${nuevo.json.id}`, "admin1", { alias: "Bodega sur" })).status, 200);
      const lista = await llamar("GET", `/api/empresas/${e1}/centros`, "coord");
      assert.ok(lista.json.some((c: { alias: string }) => c.alias === "Bodega sur"));
    });
  });

  describe("sincronización con el cliente", () => {
    it("la programación diaria deja un trabajo por integración activa", async () => {
      const r = await llamar("POST", "/interno/eventos", undefined, { tipo: "sincronizar" });
      assert.equal(r.json.encoladas, 1);
      const [clave] = p.servicios.almacen.claves("trabajos/sincronizar/");
      const t = JSON.parse(p.servicios.almacen.objetos.get(clave!)!);
      assert.equal(t.integracion_tipo, "empresas");
      assert.equal(t.secreto_ref, "paritario-prueba/integraciones/mutual-a");
    });

    it("la función de trabajos consulta al cliente, mapea los campos y la API importa", async () => {
      const t = await crearPrueba("trabajos");
      t.servicios.almacen = p.servicios.almacen; // mismo bucket
      t.respuestaCliente.cuerpo = {
        datos: [
          { nro_adherente: "A-1", rut: "76100200-7", razon_social: "Empresa 1" },
          { nro_adherente: "A-2", rut: "76200300-7", razon_social: "Empresa 2" },
          { nro_adherente: "A-5", rut: "77777777-7", razon_social: "Empresa Nueva" },
        ],
      };
      const [clave] = p.servicios.almacen.claves("trabajos/sincronizar/");
      const r = await t.app.inject({
        method: "POST",
        url: "/interno/trabajos",
        payload: { Records: [{ eventSource: "aws:s3", s3: { object: { key: clave!.replace("operaciones/", "") } } }] },
      });
      assert.equal(r.statusCode, 200, r.body);
      const http = t.llamadas.find((l) => l.tipo === "http")!.datos as { url: string; headers: Record<string, string> };
      assert.equal(http.headers.authorization, "Bearer secreto");
      await t.cerrar();

      const [imp] = p.servicios.almacen.claves("importaciones/");
      assert.ok(imp, "deja el resultado en importaciones/");
      const ev = await llamar("POST", "/interno/eventos", undefined, {
        Records: [{ eventSource: "aws:s3", s3: { object: { key: imp!.replace("operaciones/", "") } } }],
      });
      assert.equal(ev.status, 200, JSON.stringify(ev.json));
      const [s] = await sqlAdmin<{ nuevos: number; estado: string }>("SELECT nuevos, estado FROM sincronizacion ORDER BY id DESC LIMIT 1");
      assert.equal(s!.estado, "correcta");
      assert.equal(s!.nuevos, 1);
      assert.equal(p.servicios.almacen.claves("importaciones/").length, 0, "el archivo se borra al importar");
    });

    it("los trabajos de usuarios llaman a Cognito", async () => {
      const t = await crearPrueba("trabajos");
      t.servicios.almacen = p.servicios.almacen;
      const claves = p.servicios.almacen.claves("trabajos/crear_usuario/");
      await t.app.inject({
        method: "POST",
        url: "/interno/trabajos",
        payload: { Records: claves.map((k) => ({ eventSource: "aws:s3", s3: { object: { key: k.replace("operaciones/", "") } } })) },
      });
      assert.deepEqual(t.llamadas.find((l) => l.tipo === "crear")?.datos, { rut: "21212121-5", correo: "nueva@e1.cl" });
      assert.equal((await t.app.inject({ method: "GET", url: "/api/yo" })).statusCode, 404, "la función de trabajos no atiende usuarios");
      await t.cerrar();
    });
  });
});
