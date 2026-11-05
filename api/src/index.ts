// Punto de entrada. En Lambda, Lambda Web Adapter arranca este proceso y le
// reenvía las solicitudes al puerto AWS_LWA_PORT.

import { construirApp } from "./app.js";
import { verificadorCognito } from "./auth.js";
import { leerConfig } from "./config.js";
import { crearPool } from "./db.js";
import { serviciosAws } from "./servicios.js";

const cfg = leerConfig();
const pool = cfg.modo === "api" ? crearPool(cfg) : (undefined as never);
const verificarToken = cfg.modo === "api" ? verificadorCognito(cfg) : async () => {
  throw new Error("La función de trabajos no atiende usuarios");
};

const app = construirApp({ cfg, pool, servicios: serviciosAws(cfg), verificarToken });

app.listen({ host: "0.0.0.0", port: cfg.puerto }).catch((e) => {
  app.log.error(e);
  process.exit(1);
});

for (const s of ["SIGTERM", "SIGINT"] as const) {
  process.on(s, () => {
    void app.close().then(() => pool?.end());
  });
}
