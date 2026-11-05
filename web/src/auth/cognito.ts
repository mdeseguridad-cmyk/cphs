// Cognito: usuario y contraseña con SRP (la contraseña nunca viaja), con los
// desafíos de clave nueva (invitación) y de código MFA; y sistema de un
// cliente con OAuth (código + PKCE) en el dominio de Cognito.

import {
  AuthenticationDetails,
  CognitoUser,
  CognitoUserPool,
  type CognitoUserSession,
  type IAuthenticationCallback,
} from "amazon-cognito-identity-js";
import type { Config } from "../config";
import type { Autenticador, Paso } from "./autenticador";

type ConfigCognito = Extract<Config, { auth: "cognito" }>;

const FEDERADO = "paritario.federado";
const PKCE = "paritario.pkce";

interface TokensFederados {
  id: string;
  refresh: string;
  vence: number;
}

const b64url = (b: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

function venceEn(token: string): number {
  const p = JSON.parse(atob(token.split(".")[1]!.replace(/-/g, "+").replace(/_/g, "/"))) as { exp: number };
  return p.exp * 1000;
}

export function autenticadorCognito(cfg: ConfigCognito): Autenticador {
  const pool = new CognitoUserPool({ UserPoolId: cfg.userPoolId, ClientId: cfg.clientId, Storage: window.sessionStorage });
  let pendiente: CognitoUser | null = null;
  const retorno = `${location.origin}/auth/callback`;

  function callbacks(usuario: CognitoUser, resolver: (p: Paso) => void, rechazar: (e: unknown) => void): IAuthenticationCallback {
    return {
      onSuccess: () => {
        pendiente = null;
        resolver({ tipo: "listo" });
      },
      onFailure: rechazar,
      newPasswordRequired: () => {
        pendiente = usuario;
        resolver({ tipo: "nueva_clave" });
      },
      totpRequired: () => {
        pendiente = usuario;
        resolver({ tipo: "codigo_mfa" });
      },
      mfaRequired: () => {
        pendiente = usuario;
        resolver({ tipo: "codigo_mfa" });
      },
    };
  }

  async function tokenFederado(): Promise<string | null> {
    const t = JSON.parse(sessionStorage.getItem(FEDERADO) ?? "null") as TokensFederados | null;
    if (!t) return null;
    if (t.vence - Date.now() > 60_000) return t.id;
    const r = await fetch(`${cfg.cognitoDominio}/oauth2/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "refresh_token", client_id: cfg.clientId, refresh_token: t.refresh }),
    });
    if (!r.ok) {
      sessionStorage.removeItem(FEDERADO);
      return null;
    }
    const n = (await r.json()) as { id_token: string };
    sessionStorage.setItem(FEDERADO, JSON.stringify({ ...t, id: n.id_token, vence: venceEn(n.id_token) }));
    return n.id_token;
  }

  return {
    iniciar(rut, clave) {
      const usuario = new CognitoUser({ Username: rut, Pool: pool, Storage: window.sessionStorage });
      return new Promise((resolver, rechazar) =>
        usuario.authenticateUser(new AuthenticationDetails({ Username: rut, Password: clave }), callbacks(usuario, resolver, rechazar)),
      );
    },
    nuevaClave(clave) {
      const usuario = pendiente;
      if (!usuario) return Promise.reject(new Error("Vuelva a iniciar sesión"));
      return new Promise((resolver, rechazar) => usuario.completeNewPasswordChallenge(clave, {}, callbacks(usuario, resolver, rechazar)));
    },
    codigoMfa(codigo) {
      const usuario = pendiente;
      if (!usuario) return Promise.reject(new Error("Vuelva a iniciar sesión"));
      return new Promise((resolver, rechazar) => usuario.sendMFACode(codigo, callbacks(usuario, resolver, rechazar), "SOFTWARE_TOKEN_MFA"));
    },
    async federado(proveedor) {
      const verificador = b64url(crypto.getRandomValues(new Uint8Array(32)));
      const estado = b64url(crypto.getRandomValues(new Uint8Array(16)));
      const desafio = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verificador)));
      sessionStorage.setItem(PKCE, JSON.stringify({ verificador, estado }));
      const q = new URLSearchParams({
        identity_provider: proveedor,
        redirect_uri: retorno,
        response_type: "code",
        client_id: cfg.clientId,
        scope: "openid email profile",
        code_challenge: desafio,
        code_challenge_method: "S256",
        state: estado,
      });
      location.assign(`${cfg.cognitoDominio}/oauth2/authorize?${q}`);
    },
    async completarFederado(url) {
      const guardado = JSON.parse(sessionStorage.getItem(PKCE) ?? "null") as { verificador: string; estado: string } | null;
      sessionStorage.removeItem(PKCE);
      const error = url.searchParams.get("error_description") ?? url.searchParams.get("error");
      if (error) throw new Error(error);
      if (!guardado || url.searchParams.get("state") !== guardado.estado) throw new Error("El inicio de sesión no es válido. Intente de nuevo.");
      const r = await fetch(`${cfg.cognitoDominio}/oauth2/token`, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          client_id: cfg.clientId,
          code: url.searchParams.get("code") ?? "",
          redirect_uri: retorno,
          code_verifier: guardado.verificador,
        }),
      });
      if (!r.ok) throw new Error("No se pudo completar el inicio de sesión");
      const t = (await r.json()) as { id_token: string; refresh_token: string };
      sessionStorage.setItem(FEDERADO, JSON.stringify({ id: t.id_token, refresh: t.refresh_token, vence: venceEn(t.id_token) }));
    },
    async token() {
      const federado = await tokenFederado();
      if (federado) return federado;
      const usuario = pool.getCurrentUser();
      if (!usuario) return null;
      return new Promise((resolver) =>
        // getSession renueva el token con el refresh token si venció.
        usuario.getSession((e: Error | null, s: CognitoUserSession | null) => resolver(e || !s?.isValid() ? null : s.getIdToken().getJwtToken())),
      );
    },
    cerrar() {
      sessionStorage.removeItem(FEDERADO);
      pool.getCurrentUser()?.signOut();
    },
  };
}
