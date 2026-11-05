import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { pluginTokensDesarrollo } from "./dev/tokens";

// En desarrollo, /api va a la API local (puerto 8080) y el inicio de sesión
// usa tokens de prueba (dev/tokens.ts). La versión publicada usa Cognito.
export default defineConfig({
  plugins: [react(), pluginTokensDesarrollo({ jwksPath: ".dev/jwks.json" })],
  // amazon-cognito-identity-js espera la variable global de Node.
  define: { global: "globalThis" },
  server: {
    port: 5173,
    proxy: { "/api": process.env.API_URL ?? "http://localhost:8080" },
  },
  build: { sourcemap: true, chunkSizeWarningLimit: 800 },
});
