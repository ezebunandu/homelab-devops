# Homelab bring-up scripts

Three idempotent bash scripts that replace the copy-paste command blocks in the plan. Each is self-contained and safe to re-run.

| Script | Where it runs | What it does |
|---|---|---|
| `proxmox-setup.sh` | PVE node, as `root` | Node DNS, snippets storage, Terraform role/user/token |
| `traefik-setup.sh` | Traefik VM, as service user | `~/traefik/` compose stack with the v3.6.6 config that works against Docker 29 |
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
