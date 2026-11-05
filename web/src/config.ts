// Configuración en tiempo de ejecución: /config.json. La misma compilación
// sirve para cualquier entorno; scripts/publicar.sh escribe este archivo con
// las salidas de Terraform.

export interface Proveedor {
  /** Nombre del proveedor en Cognito (clave de proveedores_identidad). */
  nombre: string;
  /** Texto del botón, p. ej. "Mutualidad Ejemplo". */
  etiqueta: string;
}

export type Config =
  | { auth: "desarrollo"; entorno: string; proveedores: Proveedor[] }
  | {
      auth: "cognito";
      entorno: string;
      region: string;
      userPoolId: string;
      clientId: string;
      /** https://<dominio>.auth.<region>.amazoncognito.com; vacío sin proveedores de clientes. */
      cognitoDominio: string;
      proveedores: Proveedor[];
    };

let config: Config | null = null;

export async function cargarConfig(): Promise<Config> {
  if (config) return config;
  const r = await fetch("/config.json", { cache: "no-store" });
  if (!r.ok) throw new Error("No se encontró la configuración (config.json)");
  config = (await r.json()) as Config;
  return config;
}
