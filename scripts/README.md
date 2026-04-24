# Homelab bring-up scripts

| Script | Where it runs | What it does |
|---|---|---|
| `proxmox-setup.sh` | PVE node, as `root` | Node DNS, snippets storage, Terraform role/user/token |
| `proxmox-storage-setup.sh` | PVE node, as `root` | Extends `local-lvm` into the free tail of `/dev/sda`; optionally wipes `/dev/sdb` and creates `local-ssd` thin pool for Talos system disks |
| `traefik-setup.sh` | Traefik VM, as service user | `~/traefik/` compose stack with the v3.6.6 config that works against Docker 29; owns `dynamic.d/00-base.yml` |
| `traefik-add-pve-prod-cluster.sh` | Traefik VM, as service user | Drops `dynamic.d/20-pve-prod-cluster.yml` with routes for the 3 prod Proxmox nodes |
| `pihole-wildcard.sh` | Host running the Pi-hole container, with sudo | Writes the `address=/<subdomain>/<ip>` record, validates, reloads |

## `proxmox-setup.sh`

Run once on the Proxmox node (SSH as root, or Datacenter → node → Shell).

```bash
# Defaults match this deployment; override via env vars if needed
./proxmox-setup.sh
```

The token value is printed once when it's first created. Copy it immediately — re-running the script won't re-display it. If you lose it:

```bash
pveum user token remove terraform@pve main
./proxmox-setup.sh   # creates a new token, prints it once
```

**Env var overrides:**

```
ROLE_NAME=Terraform
USER_NAME=terraform@pve
TOKEN_NAME=main
STORAGE=local
DNS_PRIMARY=1.1.1.1
DNS_SECONDARY=8.8.8.8
```

After the script finishes, export the token on your workstation:

```bash
export TF_VAR_pve_api_token='terraform@pve!main=xxxxxxxx-...'
```

Then in `terraform/traefik-vm/`:

```bash
terraform init
terraform apply
```

## `proxmox-storage-setup.sh`

Run once on the Proxmox node (SSH as root, or Datacenter → node → Shell) ahead of provisioning the Talos cluster (DC-1). Idempotent — re-runs skip already-completed steps.

Two independent operations:

1. **Extend `local-lvm`** into the free tail of `/dev/sda`. The PVE installer only claimed ~238 GB of the 1 TB spindle; this script creates `/dev/sda4` from the unallocated space, adds it to the `pve` VG, and grows the `pve/data` thin pool. Non-destructive — only touches unallocated space.
2. **Convert `/dev/sdb`** from its existing Windows install into a fresh `local-ssd` LVM-thin pool. Dedicated fast tier for Talos system disks (scsi0) so etcd fsyncs don't sit on the spindle. **Destructive** — requires explicit confirmation.

```bash
# Dry run — extends local-lvm only; reports what would happen to /dev/sdb
./proxmox-storage-setup.sh

# Full run — also wipes /dev/sdb and creates local-ssd
CONFIRM_WIPE_SSD=yes ./proxmox-storage-setup.sh
```

**Env var overrides:**

```
HDD_DEVICE=/dev/sda
HDD_VG=pve
HDD_THINPOOL=data
SSD_DEVICE=/dev/sdb
SSD_VG=pve-ssd
SSD_THINPOOL=data
SSD_STORAGE_NAME=local-ssd
CONFIRM_WIPE_SSD=no
```

**Safety guards:** refuses to touch the HDD if `/dev/sda3` isn't the PV backing the expected VG; refuses to wipe the SSD if any partition is mounted or if the device already holds LVM PVs for any VG.

After the script finishes, `pvesm status` should show two thin-pool storages: `local-lvm` (~950 GB on the spindle) and `local-ssd` (~235 GB on the SSD).

## `traefik-setup.sh`

Run on the Traefik VM as the service user (e.g. `sam`). Safe to re-run — config files are overwritten each time and `docker compose up -d` reconciles.

```bash
export CF_DNS_API_TOKEN='<cloudflare token>'
export DASHBOARD_ADMIN_PASSWORD='<strong password>'

./traefik-setup.sh
```

**Env var overrides:**

```
LE_EMAIL=sam.ezebunandu@gmail.com
CERT_APEX=lab.hezebonica.ca
DASHBOARD_HOST=traefik.lab.hezebonica.ca
DASHBOARD_ADMIN_USER=admin
TRAEFIK_DIR=$HOME/traefik
TRAEFIK_IMAGE=traefik:v3.6.6
```

After the first successful run the wildcard LE cert is issued; subsequent runs reuse it from `~/traefik/letsencrypt/acme.json`.

The script tails the Traefik logs at the end. `Ctrl+C` stops the tail — the container keeps running.

### Directory-based `dynamic.d/`

`traefik-setup.sh` owns only `~/traefik/dynamic.d/00-base.yml` (dashboard basicauth middleware + shared `insecure-upstream` transport). Service routes belong in their own files under `dynamic.d/` — re-running `traefik-setup.sh` preserves them. Traefik's file provider watches the directory and hot-reloads on file add/remove/change.

Adding a service = drop a new file under `dynamic.d/` (or run one of the helper scripts below).

If the VM is still on the legacy single-file `~/traefik/dynamic.yml` layout, re-run `traefik-setup.sh` — it auto-migrates to `dynamic.d/99-legacy.yml` so manually-added routes are preserved. Trim the duplicated `dashboard-auth` middleware block from `99-legacy.yml` once after migration.

## `traefik-add-pve-prod-cluster.sh`

Run on the Traefik VM as the service user. Idempotent; re-running overwrites the file with the same content. Requires `dynamic.d/` to already exist.

```bash
./traefik-add-pve-prod-cluster.sh
```

**Env var overrides:**

```
PVE_PROD_1_IP=192.168.227.2
PVE_PROD_2_IP=192.168.227.3
PVE_PROD_3_IP=192.168.227.250
PVE_PROD_1_HOST=pve-prod-1.lab.hezebonica.ca
PVE_PROD_2_HOST=pve-prod-2.lab.hezebonica.ca
PVE_PROD_3_HOST=pve-prod-3.lab.hezebonica.ca
TRAEFIK_DIR=$HOME/traefik
```

No Traefik restart needed — the file provider hot-reloads within a few seconds.

## `pihole-wildcard.sh`

Run on the host running the Pi-hole Docker container (e.g. the Firewalla).

```bash
./pihole-wildcard.sh lab.hezebonica.ca 192.168.57.8
# or
SUBDOMAIN=lab.hezebonica.ca TARGET_IP=192.168.57.8 ./pihole-wildcard.sh
```

Auto-detects the `/etc/dnsmasq.d` host mount. If the container uses a different name or a non-default config location:

```
CONTAINER_NAME=pihole-v6 CONFIG_DIR=/var/lib/pihole/dnsmasq.d ./pihole-wildcard.sh ...
```

## Order for a full rebuild

```
1. scripts/proxmox-setup.sh           # on PVE node
2. terraform apply                    # from terraform/traefik-vm/ on workstation
3. scripts/pihole-wildcard.sh …       # on Pi-hole host
4. scripts/traefik-setup.sh           # on Traefik VM
```

Steps 2 and 3 can run in parallel once step 1 finishes.

For the DevOps cluster (M2), run `scripts/proxmox-storage-setup.sh` on the PVE node before `terraform apply` in `terraform/talos-cluster/`.
