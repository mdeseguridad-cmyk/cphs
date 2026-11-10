// Documentos del comité (actas, constitución, evidencias). El navegador sube
// y baja los archivos directo a S3 con URL firmadas; la API solo registra.
//
//   1. POST /api/comites/:id/documentos     registro pendiente + URL de subida
//      (exige la huella SHA-256: S3 rechaza un archivo distinto).
//   2. PUT  <url>                            el navegador sube el archivo.
//   3. POST /api/documentos/:id/confirmar    la API verifica tamaño y huella
//      en S3, guarda la versión y lo deja disponible.

import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Contexto } from "../app.js";
import { datos, fecha, id } from "../validacion.js";
import { actualizar, bitacora, insertar, uno, varios } from "../db.js";
import { conflicto, invalido, noEncontrado } from "../errores.js";
import { comiteEditable, comiteVisible } from "./comun.js";

const MAX_BYTES = 25 * 1024 * 1024;
const TIPOS_ARCHIVO = ["application/pdf", "image/jpeg", "image/png", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"];

const documentoNuevo = z.object({
  tipo: z.enum(["constitucion", "reunion", "disolucion", "capacitacion", "investigacion", "informe_auditoria", "otro"]),
  nombre: z.string().trim().min(1).max(200),
  mime: z.enum(TIPOS_ARCHIVO as [string, ...string[]]),
  tamano_bytes: z.number().int().positive().max(MAX_BYTES),
  sha256: z.string().regex(/^[0-9a-f]{64}$/, "SHA-256 en hexadecimal, minúsculas"),
  fecha_documento: fecha.optional(),
  contiene_datos_sensibles: z.boolean().optional(),
});

const hexABase64 = (hex: string) => Buffer.from(hex, "hex").toString("base64");

export function rutasDocumentos(app: FastifyInstance, ctx: Contexto): void {
  const bucket = () => ctx.cfg.documentosBucket;

  app.get("/api/comites/:id/documentos", (req) =>
    ctx.tx(req, async (c) => {
      const cm = await comiteVisible(c, id(req));
      return varios(
        c,
        `SELECT id, tipo, nombre, mime, tamano_bytes, estado, fecha_documento, fecha_carga,
                contiene_datos_sensibles, vigente
           FROM documento WHERE comite_id = $1 AND (estado = 'disponible' OR cargado_por = usuario_actual())
          ORDER BY fecha_carga DESC`,
        [cm.id],
      );
    }),
  );

  app.post("/api/comites/:id/documentos", async (req, rep) => {
    const d = datos(documentoNuevo, req.body);
    const r = await ctx.tx(req, async (c, s) => {
      const cm = await comiteEditable(c, s, id(req));
      // Las investigaciones siempre tienen datos de salud.
      const sensible = d.tipo === "investigacion" ? true : (d.contiene_datos_sensibles ?? false);
      const clave = `comites/${cm.id}/${randomUUID()}`;
      const docId = await insertar(c, "documento", {
        comite_id: cm.id,
        tipo: d.tipo,
        nombre: d.nombre,
        archivo_key: clave,
        mime: d.mime,
        tamano_bytes: d.tamano_bytes,
        sha256: d.sha256,
        fecha_documento: d.fecha_documento,
        contiene_datos_sensibles: sensible,
        cargado_por: s.usuarioId,
      });
      const subida = await ctx.servicios.almacen.urlSubida(bucket(), clave, {
        tipo: d.mime,
        tamano: d.tamano_bytes,
        sha256Base64: hexABase64(d.sha256),
      });
      return { id: docId, subida };
    });
    return rep.status(201).send(r);
  });

  app.post("/api/documentos/:id/confirmar", (req) =>
    ctx.tx(req, async (c, s) => {
      const docId = id(req);
      const doc = await uno<{ comite_id: number; archivo_key: string; tamano_bytes: number; sha256: string; estado: string }>(
        c,
        "SELECT comite_id, archivo_key, tamano_bytes, sha256, estado FROM documento WHERE id = $1",
        [docId],
      );
      if (!doc) throw noEncontrado("Documento no encontrado");
      await comiteEditable(c, s, doc.comite_id);
      if (doc.estado === "disponible") return { id: docId, estado: "disponible" };
      const cab = await ctx.servicios.almacen.cabecera(bucket(), doc.archivo_key);
      if (!cab) throw conflicto("El archivo aún no se ha subido");
      if (cab.tamano !== Number(doc.tamano_bytes) || cab.sha256Base64 !== hexABase64(doc.sha256)) {
        throw invalido("El archivo subido no coincide con el tamaño o la huella declarados");
      }
      await actualizar(c, "documento", docId, { estado: "disponible", archivo_version: cab.version });
      await bitacora(c, s.usuarioId, "crear", "documento", docId, doc.comite_id);
      return { id: docId, estado: "disponible" };
    }),
  );

  app.get("/api/documentos/:id/descarga", (req) =>
    ctx.tx(req, async (c, s) => {
      const docId = id(req);
      const doc = await uno<{ comite_id: number; archivo_key: string; archivo_version: string | null; nombre: string; mime: string | null; estado: string }>(
        c,
        "SELECT comite_id, archivo_key, archivo_version, nombre, mime, estado FROM documento WHERE id = $1",
        [docId],
      );
      if (!doc) throw noEncontrado("Documento no encontrado");
      if (doc.estado !== "disponible") throw conflicto("El documento aún no está disponible");
      const extension = doc.mime === "application/pdf" && !doc.nombre.toLowerCase().endsWith(".pdf") ? ".pdf" : "";
      const url = await ctx.servicios.almacen.urlDescarga(bucket(), doc.archivo_key, {
        nombre: doc.nombre + extension,
        version: doc.archivo_version,
      });
      await bitacora(c, s.usuarioId, "ver", "documento", docId, doc.comite_id);
      return { url };
    }),
  );
}
