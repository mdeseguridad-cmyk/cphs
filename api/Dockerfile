# Imagen de la API de Paritario. La misma imagen corre como función "api"
# (en la VPC) y como función "trabajos" (MODO=trabajos), y también fuera de
# Lambda (ECS, local): Lambda Web Adapter solo actúa dentro de Lambda.
#
# Construir para Lambda (ARM64), con las llaves públicas del user pool y los
# certificados de RDS incluidos, porque la función no tiene internet:
#
#   docker buildx build --platform linux/arm64 --provenance=false \
#     --build-arg COGNITO_EMISOR=https://cognito-idp.sa-east-1.amazonaws.com/<pool> \
#     -t <repo>:<etiqueta> --push api/
#
# api/scripts/publicar.sh hace todo esto con las salidas de Terraform.

FROM public.ecr.aws/docker/library/node:22.20.0-alpine3.22 AS construccion
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM public.ecr.aws/docker/library/node:22.20.0-alpine3.22
# Traduce las invocaciones de Lambda a HTTP (y los eventos a POST en AWS_LWA_PASS_THROUGH_PATH).
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter

ARG COGNITO_EMISOR=""
ARG REGION=sa-east-1
# "no" solo para construir sin red (pruebas locales): la imagen no podría validar tokens ni la base.
ARG DESCARGAS=si
RUN mkdir -p /opt/paritario && if [ "$DESCARGAS" = "si" ]; then \
      wget -qO /opt/paritario/rds-ca.pem "https://truststore.pki.rds.amazonaws.com/${REGION}/${REGION}-bundle.pem" && \
      if [ -n "$COGNITO_EMISOR" ]; then wget -qO /opt/paritario/jwks.json "${COGNITO_EMISOR}/.well-known/jwks.json"; fi; \
    fi

WORKDIR /app
ENV NODE_ENV=production AWS_LWA_PORT=8080
COPY --from=construccion /app/node_modules ./node_modules
COPY --from=construccion /app/dist ./dist
COPY package.json ./
USER node
EXPOSE 8080
CMD ["node", "dist/index.js"]
