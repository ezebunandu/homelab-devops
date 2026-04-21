# TLS Everywhere — Runbook

Reproducible bring-up of the homelab's edge TLS layer: Traefik on a Debian 12 VM with a wildcard Let's Encrypt cert, issued via Cloudflare DNS-01. Rationale for each choice lives in [`tls-everywhere-architecture.md`](./tls-everywhere-architecture.md); this doc is procedure.

## Facts sheet

| Variable | Value | Notes |
|---|---|---|
| Public domain | `hezebonica.ca` | Registered with Cloudflare Registrar |
| Internal subdomain | `lab.hezebonica.ca` | All LAN services live here |
| Wildcard cert | `*.lab.hezebonica.ca` (+ apex) | One cert covers everything |
| Traefik VM IP | `192.168.57.8` | Debian 12, Docker, provisioned via Terraform |
| Proxmox node | `devops` @ `192.168.57.7` | Dell T3600, PVE 9.1.1 |
| Pi-hole (internal DNS) | `172.16.0.2` | Existing container on a separate host |
| ACME email | `sam.ezebunandu@gmail.com` | Receives renewal and revocation notices |
| Cloudflare API token | (stored in password manager) | Zone-scoped, DNS:Edit only |

## Prereq 1 — Domain ownership

`hezebonica.ca` is registered with Cloudflare Registrar.

**Verify:**
```bash
dig +short NS hezebonica.ca
# Expect two *.ns.cloudflare.com nameservers
```

## Prereq 2 — Cloudflare DNS zone

Because the domain is registered at Cloudflare Registrar, the DNS zone is already active. No nameserver change needed.

**Verify:**
- Cloudflare dashboard → `hezebonica.ca` → zone status shows **Active**
- DNS tab loads and shows at least the registrar defaults

## Prereq 3 — Scoped Cloudflare API token

Do **not** use the Global API Key.

**Steps:**
1. Cloudflare dashboard → top-right profile → **My Profile** → **API Tokens** → **Create Token**
2. Choose the **Edit zone DNS** template (or Custom Token)
3. Configure:
   - Permissions: `Zone` → `DNS` → `Edit`
   - Zone Resources: `Include` → `Specific zone` → `hezebonica.ca`
   - Optional: set TTL (6–12 months) and IP restriction (home public IP if static)
4. **Continue to summary** → **Create Token**
5. Copy the token once — it is not shown again. Store in a password manager.

**Verify:**
```bash
curl -s -H "Authorization: Bearer YOUR_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify \
  | grep -o '"status":"active"'
# Expect: "status":"active"
```

## Prereq 4 — Traefik VM on Proxmox

The Traefik host is a Debian 12 VM on Proxmox, provisioned by Terraform using `bpg/proxmox`.

**Target state:**
- VM IP: `192.168.57.8`
- Node: `devops` @ `192.168.57.7` (Dell T3600, PVE 9.1.1)
- Image: Debian 12 generic cloud image (qcow2)
- User: `sam` (sudo, docker groups)
- Docker Engine + Compose v2 installed via cloud-init
- qemu-guest-agent running

**Terraform source:** `terraform/traefik-vm/` in this repo. See:
- `main.tf` — VM, image download, cloud-init snippet
- `variables.tf` — inputs
- `cloud-init.yaml.tftpl` — Docker install at first boot
- `terraform.tfvars.example` — template (copy to `terraform.tfvars`)
- `.envrc.example` — env-var token injection pattern (direnv)

**Build or rebuild:**
```bash
cd terraform/traefik-vm
terraform init
terraform apply
```

**T3600 / rebuild gotchas worth remembering:**
- Installer hangs on Quadro K4000 without `nomodeset` boot flag
- DNS needs to be set explicitly on PVE (`pvesh set /nodes/devops/dns --dns1 1.1.1.1 --dns2 8.8.8.8`) or image downloads fail
- Fresh KVM state sometimes panics new VMs on first boot — a single host reboot clears it
- Role privilege `VM.Monitor` was removed in PVE 9.x; `Datastore.Allocate` is required in addition to `AllocateSpace` for snippet uploads
- Traefik requires **v3.6.6+** on Docker 29. Earlier v3.x silently fails container discovery via the Docker provider ([traefik/traefik#12253](https://github.com/traefik/traefik/issues/12253)). Also pass static config via `command:` flags rather than a mounted `traefik.yml` — v3.6 behaves inconsistently when both are present.

## Prereq 5 — Pi-hole wildcard for `*.lab.hezebonica.ca`

Goal: a LAN client querying `grafana.lab.hezebonica.ca` receives `192.168.57.8`.

Pi-hole runs as a Docker container on a separate host at `172.16.0.2`. The script below detects the `/etc/dnsmasq.d` bind-mount, writes the wildcard record, validates dnsmasq config, and reloads.

### Run the script on the Pi-hole host

```bash
# SSH to the Pi-hole host, then from the repo checkout:
./scripts/pihole-wildcard.sh lab.hezebonica.ca 192.168.57.8
```

Syntax note: the script writes `address=/<subdomain>/<ip>` — a dnsmasq wildcard that answers for any `*.<subdomain>` name (including the apex).

### Verify from a LAN client (not from Pi-hole)

```bash
dig @172.16.0.2 +short grafana.lab.hezebonica.ca    # force the query to Pi-hole directly
dig +short grafana.lab.hezebonica.ca                # via the client's default resolver
# Both expected: 192.168.57.8
```

If the `@172.16.0.2` form answers but the plain `dig` doesn't, the client isn't using Pi-hole. Check your router's DHCP DNS setting.

### Cross-subnet note

Pi-hole (`172.16.0.0/x`) and Traefik (`192.168.57.0/24`) live on different subnets. Nothing to fix as long as:
- Your LAN clients have a route to `172.16.0.2` (they must, if Pi-hole already works for them)
- The Traefik VM has working outbound DNS (verified — cloud-init and apt both succeeded)

### Firewalla caveat

The Pi-hole config file (`/home/pi/.firewalla/run/docker/pi-hole/etc-dnsmasq.d/02-lab.conf`) lives under `/home/pi/.firewalla/run/`. Firewalla firmware updates may rebuild `run/` state and drop the wildcard. If DNS for `*.lab.hezebonica.ca` stops resolving after a Firewalla update, re-run the script.

---

## Proxmox-side setup (for Terraform provisioning)

Only needed if the Traefik host will be a VM on Proxmox provisioned by Terraform (`bpg/proxmox` provider).

### Run the setup script on the PVE node

```bash
# SSH to PVE as root, then from the repo checkout:
./scripts/proxmox-setup.sh
```

The script is idempotent and handles node DNS, snippets storage, Terraform role, user, ACL binding, and API token creation. See `scripts/README.md` for env-var overrides.

The token value is printed **once** when first created — capture it immediately.

### SSH access for the bpg provider

The provider SSHs to the node for snippet uploads. From your workstation:

```bash
ssh-copy-id root@PVE_IP
ssh root@PVE_IP 'hostname && pveversion'   # should not prompt for password
```

### Verify the token from your workstation

```bash
# Single quotes required — zsh treats ! as history expansion inside double quotes
curl -sk -H 'Authorization: PVEAPIToken=terraform@pve!main=xxxxxxxx-...' \
  https://PVE_IP:8006/api2/json/version | python3 -m json.tool
# Expect: JSON with release/version/repoid
```

### Values to record for `terraform.tfvars`

| Variable | Value |
|---|---|
| `pve_endpoint` | `https://PVE_IP:8006/` |
| `pve_api_token` | `terraform@pve!main=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `pve_node` | output of `hostname` on PVE |

---

## Main setup — Traefik

Target host: the Traefik VM at `192.168.57.8`. The bring-up is a single script invocation — see `scripts/README.md` for details and env-var overrides.

### Run the script on the VM

```bash
ssh sam@192.168.57.8
# copy the repo to the VM or just scp the script
export CF_DNS_API_TOKEN='<cloudflare token>'
export DASHBOARD_ADMIN_PASSWORD='<strong password>'
./scripts/traefik-setup.sh
```

The script:
- Creates `~/traefik/` with the correct directory + file permissions
- Writes `.env` (Cloudflare token, mode 600)
- Generates a bcrypt basicauth hash for the dashboard and writes `dynamic.yml`
- Writes `docker-compose.yml` with the working v3.6.6 configuration (static config via `command:` flags; Docker provider + file provider; dashboard via labels; basicauth middleware attached)
- Runs `docker compose up -d` and tails the logs

Expected progression in the logs:
1. Provider `docker` starts watching `/var/run/docker.sock`
2. Provider `file` loads `dynamic.yml`
3. Router `dashboard@docker` registered, requests TLS
4. ACME client contacts Cloudflare DNS API
5. DNS-01 TXT record created, Let's Encrypt validates
6. `Certificates obtained for domains [lab.hezebonica.ca *.lab.hezebonica.ca]`

End-to-end issuance is typically 30–90 seconds. `Ctrl+C` stops the log tail — the container keeps running.

### Why this specific configuration

- **Pinned to `traefik:v3.6.6`** — earlier v3.x versions silently fail to discover containers under Docker 29 ([traefik/traefik#12253](https://github.com/traefik/traefik/issues/12253))
- **Static config via `command:` flags**, not `traefik.yml` — v3.6 behaves inconsistently when both are present
- **Basicauth on dashboard from the start** — no unauthenticated surface; port 8080 is not bound
- **Docker provider + file provider together** — labels for containers on the VM, file-provider routes for off-host services

Full architectural rationale: [`tls-everywhere-architecture.md`](./tls-everywhere-architecture.md).

### Verify from a LAN client

```bash
dig +short traefik.lab.hezebonica.ca                 # expect: 192.168.57.8
curl -I https://traefik.lab.hezebonica.ca            # expect: HTTP/2 401 (basicauth)
curl -I -u admin:PASS https://traefik.lab.hezebonica.ca/api/http/middlewares
                                                      # expect: HTTP/2 200

openssl s_client -connect traefik.lab.hezebonica.ca:443 \
  -servername traefik.lab.hezebonica.ca </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
# Expected: issuer = Let's Encrypt, subject/SAN covers *.lab.hezebonica.ca, ~90d validity
```

### Troubleshooting checkpoints

| Symptom | Likely cause | Check |
|---|---|---|
| `acme.json permissions are too open` | Something reset the mode after the script ran | `stat -c %a ~/traefik/letsencrypt/acme.json` → 600 |
| `unable to generate a certificate ... no valid auth method` | Bad or expired token | `docker compose exec traefik env \| grep CF_DNS` |
| `CAA record validation failed` | Cloudflare CAA missing letsencrypt.org | Add CAA for `letsencrypt.org` in Cloudflare UI |
| TLS handshake fails from client | DNS points elsewhere or Traefik not listening | `dig +short traefik.lab.hezebonica.ca` → `192.168.57.8`; `nc -vz 192.168.57.8 443` |
| Logs say cert issued but browser still untrusted | Browser cached old self-signed cert | Full refresh / clear site data |
| Docker compose logs empty despite running container | You wrote a stray `traefik.yml` after running the script; static config collision | `rm ~/traefik/traefik.yml` and re-run the script |

---

## Adding a service

Example for Grafana:

```yaml
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    networks: [web]
    labels:
      - traefik.enable=true
      - traefik.http.routers.grafana.rule=Host(`grafana.lab.hezebonica.ca`)
      - traefik.http.routers.grafana.entrypoints=websecure
      - traefik.http.routers.grafana.tls.certresolver=cloudflare
      - traefik.http.services.grafana.loadbalancer.server.port=3000
```

No DNS change needed — the Prereq 5 wildcard already covers every `*.lab.hezebonica.ca` name.

For services **not** in Docker (bare-metal host, TV, IoT), use Traefik's file provider in `dynamic.yml`:

```yaml
http:
  routers:
    proxmox:
      rule: "Host(`proxmox.lab.hezebonica.ca`)"
      entryPoints: [websecure]
      service: proxmox
      tls:
        certResolver: cloudflare
  services:
    proxmox:
      loadBalancer:
        servers:
          - url: "https://192.168.57.7:8006"
        serversTransport: insecure-upstream
  serversTransports:
    insecure-upstream:
      insecureSkipVerify: true
```

---

## Security checklist

- [ ] `acme.json` is `chmod 600` (Traefik refuses otherwise)
- [ ] `.env` and `letsencrypt/` excluded from git
- [ ] Dashboard auth: port 8080 is not bound; `basicauth` middleware on the HTTPS dashboard router; `--api.insecure=true` is off
- [ ] API token scoped to DNS:Edit on a single zone; rotate if leaked
- [ ] ACME account email is a monitored inbox (receives renewal warnings)

## Operational notes

- Let's Encrypt rate limit: 50 certs/week/domain. The wildcard approach keeps this far under.
- Back up `acme.json` — losing it forces re-issuance on rebuild (harmless, but noisy).
- Traefik reloads Docker label changes automatically; `dynamic.yml` is watched and reloaded (`--providers.file.watch=true`). Changes to the `command:` block in `docker-compose.yml` require `docker compose up -d --force-recreate`.
- If DNS-01 fails, check: token validity, outbound UDP/TCP 53 to `1.1.1.1` / `8.8.8.8`, Cloudflare zone is Active.
- Auto-renewal: Traefik checks certs at startup and every 24h. Renews 30 days before expiry. No cron, no manual step.
