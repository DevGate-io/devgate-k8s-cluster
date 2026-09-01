# Контекст сборки: devgate-frontend/
# PNPM_VERSION зафиксирован — версия должна совпадать с той, которой сгенерирован
# pnpm-lock.yaml (локально: pnpm --version в devgate-frontend/src).
ARG PNPM_VERSION=10.33.2

FROM node:22-alpine AS deps
ARG PNPM_VERSION
RUN corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate
WORKDIR /app
# pnpm-workspace.yaml обязателен: в нём overrides и onlyBuiltDependencies,
# без него pnpm install --frozen-lockfile падает с ERR_PNPM_LOCKFILE_CONFIG_MISMATCH
COPY src/package.json src/pnpm-lock.yaml src/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

FROM node:22-alpine AS build
ARG PNPM_VERSION
RUN corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY src/ ./
ENV NEXT_TELEMETRY_DISABLED=1
# URL API, который попадёт в клиентский бандл (браузер обращается к шлюзу по /etc/hosts).
# Для SSR-запросов значение переопределяется в манифесте (k8s/apps/frontend.yaml).
ARG NEXT_PUBLIC_API_URL=http://api.devgate.gateway.local
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
RUN pnpm build

FROM node:22-alpine AS runtime
ARG PNPM_VERSION
RUN corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    HOSTNAME=0.0.0.0 \
    PORT=3000
COPY --from=build /app/.next ./.next
COPY --from=build /app/public ./public
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/next.config.ts ./next.config.ts
COPY --from=build /app/next-env.d.ts ./next-env.d.ts
CMD ["pnpm", "start"]
