#!/usr/bin/env bash
#
# traefik-add-pve-prod-cluster.sh — add file-provider routes for the three
# production Proxmox cluster nodes.
#
# Runs as the service user (e.g. sam) on the Traefik VM. Idempotent; re-running
# overwrites the file with the same content. Traefik's file provider watches
# ~/traefik/dynamic.d/ and hot-reloads — no container restart needed.
#
# Prerequisite: ~/traefik/dynamic.d/ must already exist. If the VM is still on
# the legacy single-file dynamic.yml layout, re-run scripts/traefik-setup.sh
# first; it auto-migrates to the directory layout.
#
# The upstream leg uses the 'insecure-upstream' transport defined once in
# dynamic.d/00-base.yml (owned by traefik-setup.sh).
#
# Optional env vars (defaults in brackets):
#   PVE_PROD_1_IP    [192.168.227.2]
#   PVE_PROD_2_IP    [192.168.227.3]
#   PVE_PROD_3_IP    [192.168.227.250]
#   PVE_PROD_1_HOST  [pve-prod-1.lab.hezebonica.ca]
#   PVE_PROD_2_HOST  [pve-prod-2.lab.hezebonica.ca]
#   PVE_PROD_3_HOST  [pve-prod-3.lab.hezebonica.ca]
#   TRAEFIK_DIR      [$HOME/traefik]
#
set -euo pipefail

PVE_PROD_1_IP="${PVE_PROD_1_IP:-192.168.227.2}"
PVE_PROD_2_IP="${PVE_PROD_2_IP:-192.168.227.3}"
PVE_PROD_3_IP="${PVE_PROD_3_IP:-192.168.227.250}"
PVE_PROD_1_HOST="${PVE_PROD_1_HOST:-pve-prod-1.lab.hezebonica.ca}"
PVE_PROD_2_HOST="${PVE_PROD_2_HOST:-pve-prod-2.lab.hezebonica.ca}"
PVE_PROD_3_HOST="${PVE_PROD_3_HOST:-pve-prod-3.lab.hezebonica.ca}"
TRAEFIK_DIR="${TRAEFIK_DIR:-$HOME/traefik}"

DYNAMIC_D="${TRAEFIK_DIR}/dynamic.d"
CONFIG_FILE="${DYNAMIC_D}/20-pve-prod-cluster.yml"

log() { printf '[pve-prod-cluster] %s\n' "$*"; }

if [ ! -d "${DYNAMIC_D}" ]; then
  log "ERROR: ${DYNAMIC_D} does not exist." >&2
  log "Re-run scripts/traefik-setup.sh first to adopt the dynamic.d/ layout." >&2
  exit 1
fi

log "Writing ${CONFIG_FILE}"
cat > "${CONFIG_FILE}" <<EOF
# Production Proxmox cluster — TLS termination at the edge.
# The 'insecure-upstream' transport is defined in 00-base.yml;
# self-signed PVE certs on the LAN-internal hop are acceptable.
http:
  routers:
    pve-prod-1:
      rule: "Host(\`${PVE_PROD_1_HOST}\`)"
      entryPoints: [websecure]
      service: pve-prod-1
      tls:
        certResolver: cloudflare
    pve-prod-2:
      rule: "Host(\`${PVE_PROD_2_HOST}\`)"
      entryPoints: [websecure]
      service: pve-prod-2
      tls:
        certResolver: cloudflare
    pve-prod-3:
      rule: "Host(\`${PVE_PROD_3_HOST}\`)"
      entryPoints: [websecure]
      service: pve-prod-3
      tls:
        certResolver: cloudflare
  services:
    pve-prod-1:
      loadBalancer:
        servers:
          - url: "https://${PVE_PROD_1_IP}:8006"
        serversTransport: insecure-upstream
    pve-prod-2:
      loadBalancer:
        servers:
          - url: "https://${PVE_PROD_2_IP}:8006"
        serversTransport: insecure-upstream
    pve-prod-3:
      loadBalancer:
        servers:
          - url: "https://${PVE_PROD_3_IP}:8006"
        serversTransport: insecure-upstream
EOF

log "File provider will hot-reload within a few seconds."
log ""
log "Verify from a LAN client:"
log "  dig +short ${PVE_PROD_1_HOST}       # should return the Traefik VM IP"
log "  curl -I https://${PVE_PROD_1_HOST}  # should serve the Let's Encrypt wildcard cert"
log "  (repeat for ${PVE_PROD_2_HOST}, ${PVE_PROD_3_HOST})"
