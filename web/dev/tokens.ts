// Solo desarrollo: emite tokens de prueba para usar el front sin Cognito.
//
// El servidor de Vite sirve:
//   /config.json        configuración de desarrollo (auth: "desarrollo")
//   /dev/token?rut=…    un id token firmado con una clave local, con el RUT
//                       como usuario y un sub derivado del RUT
// y escribe las llaves públicas en web/.dev/jwks.json, para que la API local
// las use (COGNITO_JWKS_PATH). Nada de esto existe en la versión publicada:
// esa usa Cognito y su config.json lo genera scripts/publicar.sh.

import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { Plugin } from "vite";
import { SignJWT, exportJWK, generateKeyPair, type CryptoKey, type KeyObject } from "jose";

export const EMISOR_DEV = "https://desarrollo.local/paritario";
export const CLIENTE_DEV = "paritario-desarrollo";

export interface ClavesDev {
  privada: CryptoKey | KeyObject;
  jwks: { keys: Record<string, unknown>[] };
}

export async function crearClavesDev(): Promise<ClavesDev> {
  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "dev", alg: "RS256", use: "sig" };
  return { privada: privateKey, jwks: { keys: [jwk] } };
}

/** sub estable por RUT: el mismo RUT entra siempre con la misma cuenta. */
export function subDesarrollo(rut: string): string {
  const h = createHash("sha256").update(`paritario-dev:${rut}`).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

export async function tokenDesarrollo(claves: ClavesDev, rut: string): Promise<string> {
  return new SignJWT({ token_use: "id", "cognito:username": rut })
    .setProtectedHeader({ alg: "RS256", kid: "dev" })
    .setSubject(subDesarrollo(rut))
    .setIssuer(EMISOR_DEV)
    .setAudience(CLIENTE_DEV)
    .setIssuedAt()
    .setExpirationTime("8h")
    .sign(claves.privada);
}

export function pluginTokensDesarrollo(o: { claves?: ClavesDev; jwksPath?: string } = {}): Plugin {
  let claves: ClavesDev | undefined = o.claves;
  return {
    name: "paritario-tokens-desarrollo",
    apply: "serve",
    async configureServer(server) {
      claves ??= await crearClavesDev();
      if (o.jwksPath) {
        mkdirSync(dirname(o.jwksPath), { recursive: true });
        writeFileSync(o.jwksPath, JSON.stringify(claves.jwks));
      }
      server.middlewares.use("/config.json", (_req, res) => {
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ auth: "desarrollo", entorno: "desarrollo", proveedores: [] }));
      });
      server.middlewares.use("/dev/token", async (req, res) => {
        const rut = new URL(req.url ?? "", "http://x").searchParams.get("rut") ?? "";
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ token: await tokenDesarrollo(claves!, rut) }));
      });
    },
  };
}
