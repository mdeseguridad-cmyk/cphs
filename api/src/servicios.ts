// Servicios externos detrás de interfaces: en producción, AWS; en pruebas,
// implementaciones en memoria.

import { randomUUID } from "node:crypto";
import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  DeleteObjectCommand,
  HeadObjectCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";
import {
  CognitoIdentityProviderClient,
  AdminCreateUserCommand,
  AdminDisableUserCommand,
  AdminEnableUserCommand,
  AdminUserGlobalSignOutCommand,
  UsernameExistsException,
  UserNotFoundException,
} from "@aws-sdk/client-cognito-identity-provider";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import type { Config } from "./config.js";

export interface Subida {
  url: string;
  /** Encabezados que el navegador debe enviar tal cual en el PUT. */
  encabezados: Record<string, string>;
}

export interface Almacen {
  poner(bucket: string, clave: string, cuerpo: string): Promise<void>;
  leer(bucket: string, clave: string): Promise<string>;
  borrar(bucket: string, clave: string): Promise<void>;
  /** URL firmada para que el navegador suba el archivo directo a S3, con su huella SHA-256. */
  urlSubida(bucket: string, clave: string, o: { tipo: string; tamano: number; sha256Base64: string }): Promise<Subida>;
  urlDescarga(bucket: string, clave: string, o: { nombre: string; version?: string | null }): Promise<string>;
  /** Tamaño, huella y versión del objeto; null si no existe. */
  cabecera(bucket: string, clave: string): Promise<{ tamano: number; sha256Base64: string | null; version: string | null } | null>;
}

export interface Correo {
  enviar(o: { para: string; asunto: string; texto: string }): Promise<void>;
}

export interface Identidad {
  crear(o: { rut: string; correo: string }): Promise<void>;
  reenviarInvitacion(rut: string): Promise<void>;
  deshabilitar(rut: string): Promise<void>;
  habilitar(rut: string): Promise<void>;
}

export interface Secretos {
  leer(nombre: string): Promise<string>;
}

export interface Servicios {
  almacen: Almacen;
  correo: Correo;
  identidad: Identidad;
  secretos: Secretos;
  /** fetch inyectable para consultar servicios de clientes. */
  http: typeof fetch;
}

/** Deja un trabajo para la función de trabajos (correo, usuarios, sincronización). */
export async function encolarTrabajo(cfg: Config, s: Servicios, tipo: string, datos: Record<string, unknown>): Promise<string> {
  const clave = `${cfg.trabajosPrefijo}${tipo}/${new Date().toISOString().slice(0, 10)}/${randomUUID()}.json`;
  await s.almacen.poner(cfg.operacionesBucket, clave, JSON.stringify({ tipo, ...datos }));
  return clave;
}

// --- Implementaciones de AWS ---------------------------------------------------

export function serviciosAws(cfg: Config): Servicios {
  const s3 = new S3Client({ region: cfg.region });
  const ses = new SESv2Client({ region: cfg.region });
  const cognito = new CognitoIdentityProviderClient({ region: cfg.region });
  const sm = new SecretsManagerClient({ region: cfg.region });
  const pool = cfg.cognito.userPoolId;

  const almacen: Almacen = {
    async poner(Bucket, Key, cuerpo) {
      await s3.send(new PutObjectCommand({ Bucket, Key, Body: cuerpo, ContentType: "application/json" }));
    },
    async leer(Bucket, Key) {
      const r = await s3.send(new GetObjectCommand({ Bucket, Key }));
      return (await r.Body?.transformToString("utf-8")) ?? "";
    },
    async borrar(Bucket, Key) {
      await s3.send(new DeleteObjectCommand({ Bucket, Key }));
    },
    async urlSubida(Bucket, Key, o) {
      const cmd = new PutObjectCommand({
        Bucket,
        Key,
        ContentType: o.tipo,
        ContentLength: o.tamano,
        ChecksumSHA256: o.sha256Base64,
      });
      const url = await getSignedUrl(s3, cmd, {
        expiresIn: 600,
        signableHeaders: new Set(["content-type", "content-length", "x-amz-checksum-sha256"]),
      });
      return {
        url,
        encabezados: { "content-type": o.tipo, "x-amz-checksum-sha256": o.sha256Base64, "x-amz-sdk-checksum-algorithm": "SHA256" },
      };
    },
    async urlDescarga(Bucket, Key, o) {
      const nombre = encodeURIComponent(o.nombre);
      const cmd = new GetObjectCommand({
        Bucket,
        Key,
        VersionId: o.version ?? undefined,
        ResponseContentDisposition: `attachment; filename*=UTF-8''${nombre}`,
      });
      return getSignedUrl(s3, cmd, { expiresIn: 300 });
    },
    async cabecera(Bucket, Key) {
      try {
        const r = await s3.send(new HeadObjectCommand({ Bucket, Key, ChecksumMode: "ENABLED" }));
        return { tamano: r.ContentLength ?? 0, sha256Base64: r.ChecksumSHA256 ?? null, version: r.VersionId ?? null };
      } catch (e) {
        if ((e as { name?: string }).name === "NotFound") return null;
        throw e;
      }
    },
  };

  const correo: Correo = {
    async enviar(o) {
      await ses.send(
        new SendEmailCommand({
          FromEmailAddress: cfg.correoRemitente,
          Destination: { ToAddresses: [o.para] },
          Content: { Simple: { Subject: { Data: o.asunto, Charset: "UTF-8" }, Body: { Text: { Data: o.texto, Charset: "UTF-8" } } } },
        }),
      );
    },
  };

  const ignorar = (...tipos: (new (...a: never[]) => Error)[]) => (e: unknown) => {
    if (tipos.some((t) => e instanceof t)) return;
    throw e;
  };

  const identidad: Identidad = {
    async crear(o) {
      await cognito
        .send(
          new AdminCreateUserCommand({
            UserPoolId: pool,
            Username: o.rut,
            UserAttributes: [
              { Name: "email", Value: o.correo },
              { Name: "email_verified", Value: "true" },
            ],
            DesiredDeliveryMediums: ["EMAIL"],
          }),
        )
        .catch(ignorar(UsernameExistsException));
    },
    async reenviarInvitacion(rut) {
      await cognito.send(new AdminCreateUserCommand({ UserPoolId: pool, Username: rut, MessageAction: "RESEND", DesiredDeliveryMediums: ["EMAIL"] }));
    },
    async deshabilitar(rut) {
      // Usuarios que entran por el sistema de un cliente no tienen cuenta propia en Cognito: basta el bloqueo en la base.
      await cognito.send(new AdminDisableUserCommand({ UserPoolId: pool, Username: rut })).catch(ignorar(UserNotFoundException));
      await cognito.send(new AdminUserGlobalSignOutCommand({ UserPoolId: pool, Username: rut })).catch(ignorar(UserNotFoundException));
    },
    async habilitar(rut) {
      await cognito.send(new AdminEnableUserCommand({ UserPoolId: pool, Username: rut })).catch(ignorar(UserNotFoundException));
    },
  };

  const secretos: Secretos = {
    async leer(nombre) {
      const r = await sm.send(new GetSecretValueCommand({ SecretId: nombre }));
      return r.SecretString ?? "";
    },
  };

  return { almacen, correo, identidad, secretos, http: fetch };
}
