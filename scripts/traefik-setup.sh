#!/usr/bin/env bash
#
# traefik-setup.sh — stand up Traefik on the host VM.
#
# Runs as the service user (e.g. sam) on the Traefik VM. Idempotent:
#   - Creates ~/traefik/ with gitignore-safe file permissions
#   - Writes .env with the Cloudflare DNS API token (mode 600)
#   - Generates a bcrypt-hashed basicauth user for the dashboard
#   - Writes dynamic.yml + docker-compose.yml with the working v3.6.6 config
#   - Starts / recreates the container
#
# Required env vars:
#   CF_DNS_API_TOKEN            Cloudflare API token (Zone:DNS:Edit scope)
#   DASHBOARD_ADMIN_PASSWORD    Password for the dashboard basicauth user
#
# Optional env vars:
#   LE_EMAIL                    default: sam.ezebunandu@gmail.com
#   CERT_APEX                   default: lab.hezebonica.ca
#   DASHBOARD_HOST              default: traefik.<CERT_APEX>
#   DASHBOARD_ADMIN_USER        default: admin
#   TRAEFIK_DIR                 default: $HOME/traefik
#   TRAEFIK_IMAGE               default: traefik:v3.6.6
#
# Requires on the host:
#   - Docker Engine + Compose v2 (cloud-init installs this)
#   - apache2-utils for htpasswd (cloud-init installs this)
#
set -euo pipefail

: "${CF_DNS_API_TOKEN:?Required: Cloudflare API token}"
: "${DASHBOARD_ADMIN_PASSWORD:?Required: password for the dashboard basicauth user}"

LE_EMAIL="${LE_EMAIL:-sam.ezebunandu@gmail.com}"
CERT_APEX="${CERT_APEX:-lab.hezebonica.ca}"
DASHBOARD_HOST="${DASHBOARD_HOST:-traefik.${CERT_APEX}}"
DASHBOARD_ADMIN_USER="${DASHBOARD_ADMIN_USER:-admin}"
TRAEFIK_DIR="${TRAEFIK_DIR:-$HOME/traefik}"
TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik:v3.6.6}"

log() { printf '[traefik-setup] %s\n' "$*"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing required command: $1" >&2
    exit 1
  fi
}

prepare_dirs() {
  log "Preparing ${TRAEFIK_DIR}"
  mkdir -p "${TRAEFIK_DIR}/letsencrypt"
  touch "${TRAEFIK_DIR}/letsencrypt/acme.json"
  chmod 600 "${TRAEFIK_DIR}/letsencrypt/acme.json"
}

write_env() {
  log "Writing ${TRAEFIK_DIR}/.env (mode 600)"
  cat > "${TRAEFIK_DIR}/.env" <<EOF
CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN}
EOF
  chmod 600 "${TRAEFIK_DIR}/.env"
}

write_dynamic() {
  log "Generating bcrypt hash for dashboard user '${DASHBOARD_ADMIN_USER}'"
  local auth_hash
  auth_hash=$(htpasswd -nbB "${DASHBOARD_ADMIN_USER}" "${DASHBOARD_ADMIN_PASSWORD}")

  log "Writing ${TRAEFIK_DIR}/dynamic.yml"
  cat > "${TRAEFIK_DIR}/dynamic.yml" <<EOF
http:
  middlewares:
    dashboard-auth:
      basicAuth:
        users:
          - '${auth_hash}'
EOF
}

write_compose() {
  log "Writing ${TRAEFIK_DIR}/docker-compose.yml"
  cat > "${TRAEFIK_DIR}/docker-compose.yml" <<EOF
services:
  traefik:
    image: ${TRAEFIK_IMAGE}
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - CF_DNS_API_TOKEN=\${CF_DNS_API_TOKEN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./dynamic.yml:/etc/traefik/dynamic.yml:ro
      - ./letsencrypt:/letsencrypt
    command:
      - "--log.level=INFO"
      - "--api.dashboard=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--providers.docker=true"
      - "--providers.docker.exposedByDefault=false"
      - "--providers.docker.network=web"
      - "--providers.file.filename=/etc/traefik/dynamic.yml"
      - "--providers.file.watch=true"
      - "--certificatesresolvers.cloudflare.acme.email=${LE_EMAIL}"
      - "--certificatesresolvers.cloudflare.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge=true"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge.provider=cloudflare"
      - "--certificatesresolvers.cloudflare.acme.dnschallenge.resolvers=1.1.1.1:53,8.8.8.8:53"
    labels:
      - traefik.enable=true
      - traefik.http.routers.dashboard.rule=Host(\`${DASHBOARD_HOST}\`)
      - traefik.http.routers.dashboard.entrypoints=websecure
      - traefik.http.routers.dashboard.tls=true
      - traefik.http.routers.dashboard.tls.certresolver=cloudflare
      - traefik.http.routers.dashboard.tls.domains[0].main=${CERT_APEX}
      - traefik.http.routers.dashboard.tls.domains[0].sans=*.${CERT_APEX}
      - traefik.http.routers.dashboard.service=api@internal
      - traefik.http.routers.dashboard.middlewares=dashboard-auth@file
    networks:
      - web

networks:
  web:
    name: web
EOF
}

start_stack() {
  log "Starting (or recreating) the stack"
  cd "${TRAEFIK_DIR}"
  docker compose up -d --remove-orphans
}

follow_logs() {
  log "Tailing logs (Ctrl+C to stop — the container keeps running)"
  cd "${TRAEFIK_DIR}"
  docker compose logs -f --tail 50 traefik
}

main() {
  require_cmd docker
  require_cmd htpasswd

  prepare_dirs
  write_env
  write_dynamic
  write_compose
  start_stack
  log "Dashboard: https://${DASHBOARD_HOST} (basicauth as ${DASHBOARD_ADMIN_USER})"
  follow_logs
}

main "$@"
