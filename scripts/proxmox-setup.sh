#!/usr/bin/env bash
#
# proxmox-setup.sh — prepare a Proxmox VE node for Terraform automation.
#
# Runs as root on the PVE node. Idempotent:
#   - Sets node-level DNS servers (so cloud-image downloads resolve)
#   - Enables "snippets" content on the 'local' datastore (cloud-init user-data)
#   - Creates a Terraform role with exactly the privileges bpg/proxmox needs
#   - Creates a terraform@pve user and binds the role at /
#   - Creates an API token if one doesn't already exist
#
# The token VALUE is printed once on creation — capture it immediately.
#
# Override via env vars:
#   ROLE_NAME       (default: Terraform)
#   USER_NAME       (default: terraform@pve)
#   TOKEN_NAME      (default: main)
#   STORAGE         (default: local)
#   DNS_PRIMARY     (default: 1.1.1.1)
#   DNS_SECONDARY   (default: 8.8.8.8)
#
set -euo pipefail

ROLE_NAME="${ROLE_NAME:-Terraform}"
USER_NAME="${USER_NAME:-terraform@pve}"
TOKEN_NAME="${TOKEN_NAME:-main}"
STORAGE="${STORAGE:-local}"
DNS_PRIMARY="${DNS_PRIMARY:-1.1.1.1}"
DNS_SECONDARY="${DNS_SECONDARY:-8.8.8.8}"

PRIVS="Datastore.Allocate Datastore.AllocateSpace Datastore.Audit Datastore.AllocateTemplate \
Pool.Allocate Pool.Audit \
Sys.Audit Sys.Console Sys.Modify \
VM.Allocate VM.Audit VM.Clone VM.Migrate VM.PowerMgmt \
VM.GuestAgent.Audit \
VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk \
VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
SDN.Use"

log() { printf '[pve-setup] %s\n' "$*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    log "Must be run as root on the PVE node" >&2
    exit 1
  fi
}

configure_dns() {
  local node
  node=$(hostname)
  log "Setting DNS on node '$node' to ${DNS_PRIMARY}, ${DNS_SECONDARY}"
  pvesh set "/nodes/${node}/dns" --dns1 "${DNS_PRIMARY}" --dns2 "${DNS_SECONDARY}" >/dev/null
}

enable_snippets() {
  local current
  current=$(pvesh get "/storage/${STORAGE}" --output-format json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("content",""))')

  if [[ ",${current}," == *,snippets,* ]]; then
    log "Snippets already enabled on storage '${STORAGE}'"
    return
  fi

  local merged="${current:+${current},}snippets"
  log "Enabling snippets on storage '${STORAGE}' (was: '${current:-<empty>}')"
  pvesh set "/storage/${STORAGE}" --content "${merged}" >/dev/null
}

ensure_role() {
  if pveum role list --output-format json \
     | python3 -c "import json,sys; sys.exit(0 if any(r['roleid']=='${ROLE_NAME}' for r in json.load(sys.stdin)) else 1)"
  then
    log "Role '${ROLE_NAME}' exists — syncing privileges"
    pveum role modify "${ROLE_NAME}" -privs "${PRIVS}"
  else
    log "Creating role '${ROLE_NAME}'"
    pveum role add "${ROLE_NAME}" -privs "${PRIVS}"
  fi
}

ensure_user() {
  if pveum user list --output-format json \
     | python3 -c "import json,sys; sys.exit(0 if any(u['userid']=='${USER_NAME}' for u in json.load(sys.stdin)) else 1)"
  then
    log "User '${USER_NAME}' exists"
  else
    log "Creating user '${USER_NAME}'"
    pveum user add "${USER_NAME}" --comment "Terraform automation"
  fi
}

ensure_acl() {
  log "Binding role '${ROLE_NAME}' to '${USER_NAME}' at /"
  pveum aclmod / -user "${USER_NAME}" -role "${ROLE_NAME}" >/dev/null
}

ensure_token() {
  local token_id="${USER_NAME}!${TOKEN_NAME}"
  if pveum user token list "${USER_NAME}" --output-format json \
     | python3 -c "import json,sys; sys.exit(0 if any(t['tokenid']=='${TOKEN_NAME}' for t in json.load(sys.stdin)) else 1)"
  then
    log "Token '${token_id}' already exists — value cannot be retrieved"
    log "  If you lost the value, delete the token and re-run:"
    log "    pveum user token remove ${USER_NAME} ${TOKEN_NAME}"
    return
  fi

  log "Creating API token '${token_id}' (privsep=0)"
  echo '------- TOKEN DETAILS — COPY NOW, SHOWN ONCE -------'
  pveum user token add "${USER_NAME}" "${TOKEN_NAME}" --privsep 0
  echo '----------------------------------------------------'
}

main() {
  require_root
  configure_dns
  enable_snippets
  ensure_role
  ensure_user
  ensure_acl
  ensure_token
  log "Done. Export the token value as TF_VAR_pve_api_token before running terraform."
}

main "$@"
