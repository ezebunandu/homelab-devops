#!/usr/bin/env bash
# upgrade-nodes.sh
#
# Prepares nodes for a Talos image change before `terraform apply`.
# Run this whenever the schematic extensions or Talos version changes.
#
# Steps:
#   1. Apply just the schematic resource to resolve the new image ID
#   2. Download the new image onto the PVE host
#   3. Upgrade each node one at a time via talosctl (A/B atomic upgrade)
#   4. Verify cluster health before handing off to terraform apply
#
# Usage:
#   bash upgrade-nodes.sh
#   terraform apply        # applies machine config changes after nodes are upgraded

set -euo pipefail

PVE_HOST="root@192.168.57.7"
TALOS_NODES=("192.168.57.20" "192.168.57.21" "192.168.57.22")
TALOSCONFIG="/tmp/tc.yaml"

# ── 1. Resolve the new schematic ID ─────────────────────────────────────────
echo "==> Resolving new schematic ID..."
terraform apply -target=talos_image_factory_schematic.this -auto-approve

SCHEMATIC=$(terraform state show talos_image_factory_schematic.this \
  | awk '/^ *id /{print $3}' | tr -d '"')
VERSION=$(terraform console <<< 'var.talos_version' 2>/dev/null | tr -d '"')

echo "    Schematic : ${SCHEMATIC}"
echo "    Version   : ${VERSION}"

# ── 2. Update download-talos-image.sh with the new schematic ─────────────────
echo "==> Updating download-talos-image.sh..."
sed -i.bak "s|^SCHEMATIC=.*|SCHEMATIC=\"${SCHEMATIC}\"|" download-talos-image.sh
sed -i.bak "s|^VERSION=.*|VERSION=\"${VERSION}\"|"       download-talos-image.sh
rm -f download-talos-image.sh.bak

# ── 3. Download the new image onto PVE ──────────────────────────────────────
DEST="/var/lib/vz/template/iso/talos-${SCHEMATIC}-${VERSION}.img"
URL="https://factory.talos.dev/image/${SCHEMATIC}/${VERSION}/metal-amd64.raw.zst"

echo "==> Downloading new image onto PVE (${PVE_HOST})..."
ssh "${PVE_HOST}" "
  if [[ -f '${DEST}' ]]; then
    echo '    Already present: ${DEST}'
    exit 0
  fi
  command -v zstd &>/dev/null || apt-get install -y zstd -qq
  echo '    Downloading ${DEST}...'
  curl -L --progress-bar '${URL}' | zstd -d > '${DEST}'
  echo '    Done.'
"

# ── 4. Refresh talosconfig ───────────────────────────────────────────────────
echo "==> Fetching talosconfig..."
terraform output -raw talosconfig > "${TALOSCONFIG}"

# ── 5. Upgrade nodes one at a time ──────────────────────────────────────────
INSTALLER="factory.talos.dev/installer/${SCHEMATIC}:${VERSION}"

for NODE in "${TALOS_NODES[@]}"; do
  echo ""
  echo "==> Upgrading ${NODE}..."
  talosctl --talosconfig "${TALOSCONFIG}" upgrade \
    --nodes "${NODE}" \
    --image "${INSTALLER}" \
    --wait
  echo "    ${NODE} done."
done

# ── 6. Verify cluster health ─────────────────────────────────────────────────
echo ""
echo "==> Verifying cluster health..."
NODE_LIST=$(IFS=,; echo "${TALOS_NODES[*]}")
talosctl --talosconfig "${TALOSCONFIG}" \
  --nodes "${NODE_LIST}" \
  health --wait-timeout 5m

echo ""
echo "==> All nodes upgraded and healthy."
echo "    Run: terraform apply"
