// Solo desarrollo: pide un token de prueba al servidor de Vite con el RUT.
// La contraseña se ignora. En la versión publicada no existe /dev/token.

import type { Autenticador } from "./autenticador";

const CLAVE = "paritario.dev.token";

export function autenticadorDesarrollo(): Autenticador {
  return {
    async iniciar(rut) {
      const r = await fetch(`/dev/token?rut=${encodeURIComponent(rut)}`);
      if (!r.ok) throw new Error("No hay servidor de tokens de desarrollo");
      sessionStorage.setItem(CLAVE, ((await r.json()) as { token: string }).token);
      return { tipo: "listo" };
    },
    async nuevaClave() {
      return { tipo: "listo" };
    },
    async codigoMfa() {
      return { tipo: "listo" };
    },
    async federado() {
      throw new Error("El inicio de sesión de clientes no está disponible en desarrollo");
    },
    async completarFederado() {},
    async token() {
      return sessionStorage.getItem(CLAVE);
    },
    cerrar() {
      sessionStorage.removeItem(CLAVE);
    },
  };
}
