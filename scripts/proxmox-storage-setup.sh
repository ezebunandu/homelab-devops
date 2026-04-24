#!/usr/bin/env bash
#
# proxmox-storage-setup.sh — prep the Proxmox node's storage for the Talos cluster.
#
# Runs as root on the PVE node. Idempotent — every step checks its own state
# before acting, and safe to re-run. Two independent operations:
#
#   1. Extend 'local-lvm' on the spindle (/dev/sda)
#      The PVE installer only claimed ~238 GB of the 1 TB disk, leaving the tail
#      unallocated. Creates /dev/sda4 from the free space, adds it to the 'pve'
#      VG, and grows the 'pve/data' thin pool. Bulk capacity for Longhorn data
#      disks (scsi1) on the Talos VMs.
#
#   2. Convert /dev/sdb into a new 'local-ssd' LVM-thin pool
#      Wipes the old Windows install on the 240 GB Intel SSD and creates a
#      dedicated thin pool. Fast tier for Talos system disks (scsi0) — keeps
#      etcd fsyncs off the spindle.
#
# Operation 2 is destructive and requires explicit confirmation:
#   CONFIRM_WIPE_SSD=yes ./proxmox-storage-setup.sh
#
# Without CONFIRM_WIPE_SSD, the script still runs operation 1 and will report
# what it would do to /dev/sdb, but won't touch it.
#
# Override via env vars:
#   HDD_DEVICE         (default: /dev/sda)      spindle device
#   HDD_VG             (default: pve)           existing VG on HDD_DEVICE
#   HDD_THINPOOL       (default: data)          thin pool LV inside HDD_VG
#   SSD_DEVICE         (default: /dev/sdb)      SSD device (WILL BE WIPED)
#   SSD_VG             (default: pve-ssd)       new VG name on SSD_DEVICE
#   SSD_THINPOOL       (default: data)          new thin pool LV inside SSD_VG
#   SSD_STORAGE_NAME   (default: local-ssd)     PVE storage name to register
#   CONFIRM_WIPE_SSD   (default: no)            must be 'yes' to wipe SSD_DEVICE
#
set -euo pipefail

HDD_DEVICE="${HDD_DEVICE:-/dev/sda}"
HDD_VG="${HDD_VG:-pve}"
HDD_THINPOOL="${HDD_THINPOOL:-data}"
SSD_DEVICE="${SSD_DEVICE:-/dev/sdb}"
SSD_VG="${SSD_VG:-pve-ssd}"
SSD_THINPOOL="${SSD_THINPOOL:-data}"
SSD_STORAGE_NAME="${SSD_STORAGE_NAME:-local-ssd}"
CONFIRM_WIPE_SSD="${CONFIRM_WIPE_SSD:-no}"

log() { printf '[pve-storage] %s\n' "$*"; }
err() { printf '[pve-storage] ERROR: %s\n' "$*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "must be run as root on the PVE node"
    exit 1
  fi
}

require_tools() {
  local t missing=()
  for t in sgdisk parted partprobe pvs vgs lvs pvcreate vgcreate vgextend \
           lvcreate lvextend wipefs udevadm pvesh pvesm lsblk; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if (( ${#missing[@]} )); then
    err "missing required tools: ${missing[*]}"
    err "install with: apt-get install -y gdisk parted lvm2 util-linux"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# HDD — extend the existing 'pve' VG into the unallocated tail of /dev/sda
# ---------------------------------------------------------------------------

extend_hdd_vg() {
  local dev="${HDD_DEVICE}"
  local vg="${HDD_VG}"
  local pool="${HDD_THINPOOL}"
  local part="${dev}4"

  log "=== Extending '${vg}' VG on ${dev} ==="

  # Sanity: confirm ${dev}3 is the PV backing ${vg}. Guards against running
  # this on the wrong disk.
  local pv3_vg
  pv3_vg=$(pvs --noheadings -o vg_name "${dev}3" 2>/dev/null | xargs || true)
  if [[ -z "${pv3_vg}" ]]; then
    err "${dev}3 is not an LVM PV — refusing to touch ${dev}"
    err "set HDD_DEVICE to the disk hosting the '${vg}' VG"
    exit 1
  fi
  if [[ "${pv3_vg}" != "${vg}" ]]; then
    err "${dev}3 belongs to VG '${pv3_vg}', expected '${vg}'"
    exit 1
  fi

  # Step 1 — create ${dev}4 from the free tail, if not already present
  if [[ -b "${part}" ]]; then
    log "${part} already exists; skipping partition creation"
  else
    log "Free space on ${dev} before partitioning:"
    parted -s "${dev}" unit GB print free | sed 's/^/  /'

    log "Creating ${part} (type Linux LVM) from the free tail of ${dev}"
    sgdisk -n 4:0:0 -t 4:8E00 "${dev}"
    partprobe "${dev}"
    udevadm settle
    if [[ ! -b "${part}" ]]; then
      err "${part} did not appear after partprobe; aborting"
      exit 1
    fi
  fi

  # Step 2 — ensure ${part} is an LVM PV
  if pvs --noheadings -o pv_name "${part}" >/dev/null 2>&1; then
    log "${part} already a PV"
  else
    log "Creating PV on ${part}"
    pvcreate "${part}"
  fi

  # Step 3 — ensure ${part} is in ${vg}
  local part_vg
  part_vg=$(pvs --noheadings -o vg_name "${part}" 2>/dev/null | xargs || true)
  if [[ "${part_vg}" == "${vg}" ]]; then
    log "${part} already in VG '${vg}'"
  elif [[ -z "${part_vg}" ]]; then
    log "Adding ${part} to VG '${vg}'"
    vgextend "${vg}" "${part}"
  else
    err "${part} is in VG '${part_vg}', expected '${vg}' (or unassigned)"
    exit 1
  fi

  # Step 4 — grow the thin pool to consume all VG free space
  local vg_free_b
  vg_free_b=$(vgs --noheadings --nosuffix --units B -o vg_free "${vg}" | awk '{print $1}')
  # Leave anything under 1 GB alone — LVM rounds to PE boundaries and the
  # last sliver isn't worth an lvextend call that might no-op-error.
  if (( vg_free_b < 1073741824 )); then
    log "Thin pool '${vg}/${pool}' already consumes the VG (free: ${vg_free_b} B)"
  else
    log "Extending thin pool '${vg}/${pool}' by $(( vg_free_b / 1024 / 1024 / 1024 )) GB"
    lvextend -l +100%FREE "${vg}/${pool}"
  fi
}

# ---------------------------------------------------------------------------
# SSD — wipe /dev/sdb and create a new 'local-ssd' thin pool
# ---------------------------------------------------------------------------

ensure_pve_storage_registered() {
  local storage="$1" vg="$2" pool="$3"
  if pvesh get "/storage/${storage}" >/dev/null 2>&1; then
    log "PVE storage '${storage}' already registered"
    return
  fi
  log "Registering PVE storage '${storage}' (lvmthin, vg=${vg}, thinpool=${pool})"
  pvesm add lvmthin "${storage}" \
    --vgname "${vg}" \
    --thinpool "${pool}" \
    --content images,rootdir \
    --nodes "$(hostname -s)"
}

wipe_ssd_and_create_pool() {
  local dev="${SSD_DEVICE}"
  local vg="${SSD_VG}"
  local pool="${SSD_THINPOOL}"
  local storage="${SSD_STORAGE_NAME}"

  log "=== Converting ${dev} to '${storage}' (lvmthin) ==="

  # If the VG already exists, the wipe has already happened — just verify and
  # ensure PVE storage registration.
  if vgs "${vg}" >/dev/null 2>&1; then
    log "VG '${vg}' already exists on ${dev}; skipping wipe"
    if ! lvs "${vg}/${pool}" >/dev/null 2>&1; then
      err "VG '${vg}' exists but thin pool LV '${pool}' is missing"
      err "inspect manually: lvs ${vg}"
      exit 1
    fi
    ensure_pve_storage_registered "${storage}" "${vg}" "${pool}"
    return
  fi

  log "Current state of ${dev}:"
  lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT "${dev}" | sed 's/^/  /'

  if [[ "${CONFIRM_WIPE_SSD}" != "yes" ]]; then
    log "Skipping ${dev} wipe — CONFIRM_WIPE_SSD is not 'yes'"
    log "  To proceed, re-run with:"
    log "    CONFIRM_WIPE_SSD=yes $0"
    return
  fi

  # Guard: refuse if anything on ${dev} is currently mounted
  if lsblk -no MOUNTPOINT "${dev}" | grep -q . ; then
    err "${dev} has mounted partitions — unmount before wiping"
    lsblk -o NAME,MOUNTPOINT "${dev}" | sed 's/^/  /' >&2
    exit 1
  fi

  # Guard: refuse if it already holds LVM PVs (of any VG) — we'd be clobbering
  # something we didn't create.
  if pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | grep -q "^${dev}"; then
    err "${dev} already holds LVM PV(s) — refusing to wipe blindly"
    pvs | sed 's/^/  /' >&2
    exit 1
  fi

  log "Wiping ${dev}"
  wipefs -a "${dev}"
  sgdisk -Z "${dev}"
  partprobe "${dev}"
  udevadm settle

  log "Creating PV on ${dev}"
  pvcreate "${dev}"

  log "Creating VG '${vg}' on ${dev}"
  vgcreate "${vg}" "${dev}"

  log "Creating thin pool '${vg}/${pool}' consuming full VG"
  lvcreate -l 100%FREE --thinpool "${pool}" "${vg}"

  ensure_pve_storage_registered "${storage}" "${vg}" "${pool}"
}

# ---------------------------------------------------------------------------

main() {
  require_root
  require_tools
  extend_hdd_vg
  wipe_ssd_and_create_pool
  log "=== Done ==="
  log "Final PVE storage status:"
  pvesm status | sed 's/^/  /'
}

main "$@"
