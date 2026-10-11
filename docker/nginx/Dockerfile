# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim AS player-build
WORKDIR /app
COPY frontend-app/package.json frontend-app/package-lock.json ./
RUN npm ci
COPY frontend-app/ ./
RUN npm run build

FROM node:22-bookworm-slim AS profile-build
WORKDIR /app
COPY frontend-admin/package.json frontend-admin/package-lock.json ./
RUN npm ci
COPY frontend-admin/ ./
RUN npm run build

FROM nginx:1.28-alpine AS runtime
COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --from=player-build /app/dist/ /usr/share/nginx/html/
COPY --from=profile-build /app/dist/ /usr/share/nginx/html/profile/
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=5 \
    CMD wget -q -O /dev/null http://127.0.0.1/nginx-health || exit 1
