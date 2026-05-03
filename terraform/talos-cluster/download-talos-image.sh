#!/usr/bin/env bash
# download-talos-image.sh
#
# Downloads the Talos Linux disk image from the Image Factory onto the Proxmox host.
# Must be run directly on the PVE node (or via `ssh root@<pve-ip> bash < download-talos-image.sh`).
#
# WHY THIS EXISTS
# ---------------
# The bpg/proxmox Terraform provider has a `proxmox_virtual_environment_download_file` resource
# that can pull images from the internet, but it makes a `query-url-metadata` API call that
# fails with EHOSTUNREACH in environments where the Proxmox API is not directly reachable from
# the Terraform client (e.g. behind Firewalla with ARP filtering). The image is therefore
# downloaded manually as a one-time pre-flight step and referenced by path in the VM disk config.
#
# WHY THE IMAGE FACTORY
# ---------------------
# The official Talos GitHub releases ship the metal image as an XZ-compressed archive (.raw.xz).
# The bpg/proxmox provider only supports gz, lzo, zst, and bz2 compression. The Talos Image
# Factory (factory.talos.dev) serves the same image as .raw.zst (zstandard), which the provider
# accepts. The factory also allows embedding extensions into the image via a schematic — we use
# this to bake in the qemu-guest-agent extension so Proxmox can report VM IPs and coordinate
# graceful shutdown without needing a separate install step.
#
# SCHEMATIC
# ---------
# The schematic ID is a deterministic content hash. The same extension list always produces the
# same ID — submitting it to the factory is idempotent. The ID below encodes:
#   customization.systemExtensions.officialExtensions:
#     - siderolabs/qemu-guest-agent   (Proxmox IP reporting + graceful shutdown)
#     - siderolabs/iscsi-tools        (iscsid for Longhorn)
#     - siderolabs/util-linux-tools   (nsenter for Longhorn system pod operations)
#
# To regenerate the schematic (e.g. add extensions), post the YAML to factory.talos.dev and
# update SCHEMATIC below. VERSION can be updated independently.

set -euo pipefail

SCHEMATIC="53513e54bb39202f35694412577a6bc53d484744d35a126e5d42ef34785c0d83"
VERSION="v1.12.6"
DEST_DIR="/var/lib/vz/template/iso"
FILENAME="talos-${SCHEMATIC}-${VERSION}.img"
DEST="${DEST_DIR}/${FILENAME}"
URL="https://factory.talos.dev/image/${SCHEMATIC}/${VERSION}/metal-amd64.raw.zst"

# ── dependency check ────────────────────────────────────────────────────────────
if ! command -v zstd &>/dev/null; then
  echo "Installing zstd..."
  apt-get install -y zstd -qq
fi

# ── skip if already downloaded ──────────────────────────────────────────────────
if [[ -f "$DEST" ]]; then
  echo "Image already present: ${DEST}"
  echo "Delete the file and re-run to force a fresh download."
  exit 0
fi

# ── download and decompress ─────────────────────────────────────────────────────
echo "Downloading Talos ${VERSION} (schematic: ${SCHEMATIC:0:12}…)"
echo "  Source: ${URL}"
echo "  Dest:   ${DEST}"
echo ""

curl -L --progress-bar "${URL}" | zstd -d > "${DEST}"

echo ""
echo "Done. Image written to ${DEST}"
echo ""
echo "Verify in Proxmox:"
echo "  ls -lh ${DEST}"
echo ""
echo "Terraform file_id reference:"
echo "  local:iso/${FILENAME}"
