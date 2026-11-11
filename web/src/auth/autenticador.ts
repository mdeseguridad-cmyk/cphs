// Inicio de sesión. En producción, Cognito: usuario y contraseña (SRP, con
// clave temporal de la invitación y MFA) o el sistema de un cliente (OAuth
// con PKCE). En desarrollo, tokens de prueba del servidor de Vite.
//
// La sesión vive en sessionStorage: se cierra con la pestaña.

import type { Config } from "../config";
import { autenticadorCognito } from "./cognito";
import { autenticadorDesarrollo } from "./desarrollo";

export type Paso = { tipo: "listo" } | { tipo: "nueva_clave" } | { tipo: "codigo_mfa" };

export interface Autenticador {
  iniciar(rut: string, clave: string): Promise<Paso>;
  nuevaClave(clave: string): Promise<Paso>;
  codigoMfa(codigo: string): Promise<Paso>;
  /** Redirige al sistema de un cliente. */
  federado(proveedor: string): Promise<void>;
  /** Procesa el retorno desde el sistema del cliente (/auth/callback). */
  completarFederado(url: URL): Promise<void>;
  /** Token de identidad vigente (renovado si hace falta) o null. */
  token(): Promise<string | null>;
  cerrar(): void;
}

let actual: Autenticador | null = null;

export function crearAutenticador(cfg: Config): Autenticador {
  actual = cfg.auth === "desarrollo" ? autenticadorDesarrollo() : autenticadorCognito(cfg);
  return actual;
}

export function autenticador(): Autenticador {
  if (!actual) throw new Error("Autenticador no inicializado");
  return actual;
}

/** Mensajes de Cognito en español. */
export function mensajeError(e: unknown): string {
  const code = (e as { code?: string; name?: string })?.code ?? (e as { name?: string })?.name;
  switch (code) {
    case "NotAuthorizedException": {
      // Cognito usa el mismo código para varias causas; el mensaje las distingue.
      const m = (e as Error)?.message ?? "";
      if (/attempts exceeded/i.test(m)) return "Demasiados intentos fallidos. Espere unos 15 minutos antes de volver a intentar.";
      if (/disabled/i.test(m)) return "Su cuenta está deshabilitada. Pida al administrador de su empresa que la revise.";
      if (/temporary password has expired/i.test(m)) return "Su clave temporal venció. Pida al administrador que le reenvíe la invitación.";
      return "RUT o contraseña incorrectos.";
    }
    case "UserNotFoundException":
      return "RUT o contraseña incorrectos.";
    case "PasswordResetRequiredException":
      return "Debe restablecer su contraseña.";
    case "CodeMismatchException":
      return "Código incorrecto.";
    case "InvalidPasswordException":
      return "La contraseña no cumple los requisitos: al menos 10 caracteres, con mayúsculas, minúsculas y números.";
    case "ResourceNotFoundException":
      return "El inicio de sesión no está bien configurado (config.json no coincide con Cognito). Avise al administrador.";
    case "LimitExceededException":
    case "TooManyRequestsException":
      return "Demasiados intentos. Espere unos minutos.";
    default:
      return (e as Error)?.message || "No se pudo iniciar sesión.";
  }
}
