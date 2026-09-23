# Canary dashboard: build the React/Vite SPA, then serve it with nginx, which
# also reverse-proxies the backend (REST, WebSocket, /health, /docs) so the
# browser only ever talks to one origin. Both base images are multi-arch and
# build natively on a Raspberry Pi (arm64).

FROM node:22-alpine AS build
WORKDIR /web
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
# Empty API base = same origin: the dashboard calls /api/... on whatever host
# served it (http://<pi-ip>/) and nginx forwards that to the backend container.
ARG VITE_API_BASE=""
RUN VITE_API_BASE="${VITE_API_BASE}" npm run build

FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /web/dist /usr/share/nginx/html
EXPOSE 80
