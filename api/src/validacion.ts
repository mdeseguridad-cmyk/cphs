// Validación de entradas compartida por las rutas.

import type { FastifyRequest } from "fastify";
import { z } from "zod";
import { invalido, noEncontrado } from "./errores.js";

export function datos<T extends z.ZodType>(esquema: T, valor: unknown): z.infer<T> {
  const r = esquema.safeParse(valor ?? {});
  if (!r.success) {
    throw invalido(
      "Datos inválidos",
      r.error.issues.map((i) => ({ campo: i.path.join("."), mensaje: i.message })),
    );
  }
  return r.data;
}

export function id(req: FastifyRequest, nombre = "id"): number {
  const v = Number((req.params as Record<string, string>)[nombre]);
  if (!Number.isSafeInteger(v) || v <= 0) throw noEncontrado();
  return v;
}

export const fecha = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Fecha AAAA-MM-DD");
export const rut = z
  .string()
  .transform((v) => v.replace(/[.\s]/g, "").toUpperCase())
  .refine((v) => /^\d{6,8}-[\dK]$/.test(v), "RUT con formato 12345678-5");
