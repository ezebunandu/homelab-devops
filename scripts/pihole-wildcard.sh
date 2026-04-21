#!/usr/bin/env bash
#
# pihole-wildcard.sh — add a dnsmasq wildcard record to a Pi-hole container.
#
# Runs on the host running the Pi-hole Docker container (e.g. Firewalla).
# Writes a file of the form:
#   address=/<subdomain>/<target-ip>
# into the container's dnsmasq.d directory, then reloads dnsmasq.
#
# Usage:
#   pihole-wildcard.sh <subdomain> <target-ip>
#   SUBDOMAIN=lab.hezebonica.ca TARGET_IP=192.168.57.8 pihole-wildcard.sh
#
# Optional env vars:
#   CONTAINER_NAME   default: pihole
#   CONFIG_DIR       default: auto-detected from container mounts
#   CONF_BASENAME    default: 02-lab.conf
#
set -euo pipefail

SUBDOMAIN="${1:-${SUBDOMAIN:-}}"
TARGET_IP="${2:-${TARGET_IP:-}}"
CONTAINER_NAME="${CONTAINER_NAME:-pihole}"
CONFIG_DIR="${CONFIG_DIR:-}"
CONF_BASENAME="${CONF_BASENAME:-02-lab.conf}"

if [[ -z "${SUBDOMAIN}" || -z "${TARGET_IP}" ]]; then
  printf 'Usage: %s <subdomain> <target-ip>\n' "$0" >&2
  printf '   or: SUBDOMAIN=... TARGET_IP=... %s\n' "$0" >&2
  exit 1
fi

log() { printf '[pihole-wildcard] %s\n' "$*"; }

SUDO=""
if [[ $EUID -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    log "Not root and sudo is not available" >&2
    exit 1
  fi
  SUDO=sudo
fi

detect_config_dir() {
  if [[ -n "${CONFIG_DIR}" ]]; then
    log "Using provided CONFIG_DIR=${CONFIG_DIR}"
    return
  fi

  log "Auto-detecting /etc/dnsmasq.d mount for container '${CONTAINER_NAME}'"
  CONFIG_DIR=$(${SUDO} docker inspect "${CONTAINER_NAME}" \
    --format '{{range .Mounts}}{{if eq .Destination "/etc/dnsmasq.d"}}{{.Source}}{{end}}{{end}}')

  if [[ -z "${CONFIG_DIR}" ]]; then
    log "No host mount for /etc/dnsmasq.d in container '${CONTAINER_NAME}'" >&2
    log "Set CONFIG_DIR=... explicitly, or choose a different CONTAINER_NAME" >&2
    exit 1
  fi
  log "Detected: ${CONFIG_DIR}"
}

write_record() {
  local conf_path="${CONFIG_DIR}/${CONF_BASENAME}"
  local conf_line="address=/${SUBDOMAIN}/${TARGET_IP}"
  log "Writing ${conf_path}"
  echo "${conf_line}" | ${SUDO} tee "${conf_path}" >/dev/null
}

validate_config() {
  log "Validating dnsmasq config inside the container"
  if ${SUDO} docker exec "${CONTAINER_NAME}" pihole-FTL --test >/dev/null 2>&1; then
    log "  syntax OK"
  else
    log "  syntax validation failed:" >&2
    ${SUDO} docker exec "${CONTAINER_NAME}" pihole-FTL --test >&2 || true
    exit 1
  fi
}

reload_dns() {
  log "Reloading dnsmasq"
  ${SUDO} docker exec "${CONTAINER_NAME}" pihole restartdns >/dev/null
}

main() {
  detect_config_dir
  write_record
  validate_config
  reload_dns
  log "Done. Verify from a LAN client:"
  log "  dig +short test.${SUBDOMAIN}   # expect: ${TARGET_IP}"
}

main "$@"
