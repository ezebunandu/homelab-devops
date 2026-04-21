# TLS Everywhere — Architecture Write-up

Implementation record for the homelab's edge TLS setup. Focuses on **why each choice was made**; the reproducible procedure lives in [`tls-everywhere-runbook.md`](./tls-everywhere-runbook.md). Project-level framing is in [`README.md`](./README.md).

## Problem statement

Every LAN service (Proxmox UI, Pi-hole admin, future Grafana, GitLab, Harbor, etc.) served self-signed certificates. Browsers showed scary warnings; clients had to either click through every time, add per-service CA exceptions, or disable TLS entirely. Inconsistent, insecure by muscle memory, and ugly.

Goals:

- **Publicly-valid certificates on LAN-only services** — no click-through warnings anywhere
- **No service exposure to the public internet** — LAN stays LAN
- **Single operational surface** for cert issuance, renewal, and TLS config
- **Low ongoing maintenance** — a homelab shouldn't need weekly attention
- **Extensible** — the setup should carry through the planned k8s cluster migration

## High-level shape

```
Public internet
  Let's Encrypt ACME ◄──────┐
                            │ DNS-01 TXT records (cert issuance only)
  Cloudflare DNS ◄──────────┘
    authoritative for hezebonica.ca
─────────────────────────────────────────────────────────────────────
Home LAN (192.168.57.0/24)
  LAN clients
    │ DNS query for *.lab.hezebonica.ca
    ▼
  Pi-hole (172.16.0.2) — split-horizon resolver
    │ wildcard answer → 192.168.57.8
    ▼
  Traefik VM (192.168.57.8) — reverse proxy + TLS termination
    │ real Let's Encrypt cert for *.lab.hezebonica.ca
    │
    ├─► labeled Docker services on the Traefik VM
    └─► file-provider routes to off-host services
           (Proxmox UI, future k8s MetalLB IPs)
```

Three external dependencies, clearly scoped:

- **Cloudflare** — registrar + authoritative DNS only. Doesn't proxy traffic.
- **Let's Encrypt** — issues the wildcard cert. Auto-renewal every ~60 days.
- **Pi-hole** — existing LAN DNS resolver; adds one wildcard record.

## Major choices, with rationale

### 1. Real public domain + DNS-01 challenge — not self-signed, not HTTP-01

Alternatives considered:

- **Self-signed certs with an internal CA** (smallstep, cfssl, mkcert). Rejected because every new device / browser needs the CA trust pre-loaded. That scales badly to guests, IoT, family phones.
- **HTTP-01 challenge** — requires the ACME client to answer on a public IP during issuance. That means port 80 open to the internet, which defeats the "LAN stays LAN" goal.
- **TLS-ALPN-01** — same problem: needs public reachability on port 443.

**DNS-01 is the only ACME challenge that works for entirely-private services.** You prove domain ownership by writing a TXT record to a DNS provider with API access. Let's Encrypt never needs to reach the services themselves — it only queries public DNS for a TXT record that expires in minutes.

Cost: you must own a real domain and use a DNS provider with an API. Both are cheap/free.

### 2. Cloudflare as DNS + registrar — simplicity win

`hezebonica.ca` is registered directly with Cloudflare Registrar (at-cost pricing, no upsells, no transfer required later). Cloudflare's API token system is well-scoped (`Zone:DNS:Edit`, restricted to the specific zone), and their DNS API is first-class supported by every ACME client.

Alternatives like Namecheap/Porkbun work fine but require extra steps to change nameservers. Skipping them simplifies the bootstrap.

### 3. Single wildcard certificate — not per-service certs

The Traefik-issued cert covers:

- `lab.hezebonica.ca` (apex)
- `*.lab.hezebonica.ca` (wildcard)

One cert covers every current and future service. Benefits:

- **One ACME call every ~60 days** — stays well under Let's Encrypt's 50-certs-per-week-per-domain rate limit
- **No cert config per service** — adding a new service is purely DNS + router config
- **No DNS leakage of service names** — the cert's SANs don't list every service (just the wildcard)

Cost: all covered services live under one subdomain (`lab.hezebonica.ca`) and share a single cryptographic identity. Acceptable at homelab scale.

### 4. Dedicated Traefik VM — not containers-on-every-host

Traefik runs on its own VM (`192.168.57.8`). Every HTTPS connection to any LAN service terminates here first.

Alternatives:

- **Traefik per Docker host**: each host would need its own cert, its own ACME token, its own renewal tracking. Multiplies the failure surface.
- **Traefik in k8s as ingress**: premature. The k8s cluster came after this work, and the TLS-everywhere goal is broader than k8s services.
- **No reverse proxy — certs on each service**: services like Proxmox don't support ACME natively; you'd hand-copy certs every 90 days or run a cert-sync script per host.

Centralized termination simplifies operations: one cert, one cert store, one set of logs, one renewal schedule. The VM is trivial to recreate from Terraform if lost.

### 5. Split-horizon DNS via Pi-hole — not NAT hairpinning, not Cloudflare-proxied

LAN clients resolve `*.lab.hezebonica.ca` to an internal IP (`192.168.57.8`) via Pi-hole. Public DNS (Cloudflare) has no A records for these names — only the cert-validation TXT records that exist for seconds during issuance.

Alternatives:

- **Point public DNS at your home IP + port forward** — exposes services to the internet.
- **Cloudflare Tunnel** — works but adds dependency, overhead, and latency for LAN traffic.
- **NAT hairpinning** — LAN clients try to go out and back in via the public IP. Often broken on consumer routers.

Pi-hole was already running (for ad-blocking) — adding a single wildcard record took one line in `/etc/dnsmasq.d/`.

## VM sizing and placement

| Resource | Value | Rationale |
|---|---|---|
| vCPU | 2 (host passthrough) | Traefik is mostly I/O-bound; 2 vCPU handles thousands of req/s on a homelab. |
| RAM | 2 GB | Idle ~80 MB; headroom for log spikes, ACME retries, ~10 Docker containers discovered via labels. |
| Root disk | 20 GB (thin-provisioned) | OS + Docker images + `acme.json` + docker-compose state; ~3 GB actually used. |
| NIC | single, on `vmbr0`, static `192.168.57.8/24` | Flat LAN, no VLANs. Static to pin the wildcard DNS target. |
| OS | Debian 12 cloud image | Long-term stable, cloud-init support, glibc (trouble-free Docker), broadly documented. |

Why **Debian 12 cloud** over alternatives:

- **Not Alpine**: musl sometimes bites vendored Go binaries (Docker images built for glibc). Less friction to avoid.
- **Not Ubuntu**: Snap store, auto-updater opinionated defaults, and Canonical's release cadence aren't worth it over Debian for a Docker host.
- **Not Flatcar / Fedora CoreOS**: immutable + auto-update + Ignition configs. Great fit conceptually, but adds learning curve. Deferred for the k8s cluster (which uses Talos — same immutability story, just for k8s).

## Terraform IaC

`terraform/traefik-vm/` provisions the VM from scratch. Choices:

### Provider: `bpg/proxmox` not `Telmate/proxmox`

The `Telmate/proxmox` provider is older and more widely referenced, but maintenance is inconsistent and it lags PVE API changes. `bpg/proxmox` is actively maintained, has cleaner resource shapes, handles cloud-init snippets natively, and tracks PVE 9.x properly. Small cost: fewer Stack Overflow hits. Worth it.

### Cloud-init snippet, uploaded via Proxmox's API

The provider writes cloud-init user-data as a PVE "snippet" and attaches it to the VM at boot. The template (`cloud-init.yaml.tftpl`) installs Docker Engine + Compose via the official Debian repo and adds the admin user to the `docker` group. No shell on the VM is needed during bring-up — the VM self-assembles.

### Secret handling — `TF_VAR_` env + direnv

`terraform.tfvars` is gitignored; the Cloudflare token and PVE API token are passed via environment variables (`TF_VAR_pve_api_token`, etc.). `.envrc.example` in the module documents three ways to inject: plain export, 1Password CLI, or macOS Keychain. Direnv auto-loads `.envrc` on `cd`, so the shell workflow is unchanged.

This keeps secrets out of the repo while avoiding the complexity of a secret manager for a two-token bootstrap.

### State management — local, gitignored

Terraform state lives locally in `.tfstate` files, gitignored. Acceptable because:

- Only one operator
- State is reproducible from the code + current PVE state
- No blast radius for state loss — a new apply rebuilds the VM cleanly

Future: once Vault is running in the devops cluster, state can move to Vault KV or an S3 backend on the planned NAS.

### Proxmox-side prerequisites (captured in the plan)

- Dedicated `terraform@pve` user with a scoped `Terraform` role (not root)
- API token with `privsep=0` so the token inherits the user's privileges
- `Snippets` content type enabled on the `local` datastore (needed for cloud-init user-data)
- `Datastore.Allocate` **and** `Datastore.AllocateSpace` privileges (both required as of PVE 9; the former for snippet upload, the latter for disk allocation)
- `VM.Monitor` privilege was removed in PVE 9 — listing it in the role definition will reject the whole call

Two of these last four cost debugging time during bring-up and are now documented.

## Traefik's role

Traefik v3.6.6 runs in Docker on the VM, bound to ports 80 and 443. It does three jobs:

1. **TLS termination at the edge.** Serves the wildcard Let's Encrypt cert to clients. Upstream connections to services can be plaintext HTTP or HTTPS.
2. **HTTP(S) routing.** Matches `Host` headers to routers, routers to services, services to upstream URLs.
3. **ACME client.** Talks to Let's Encrypt to issue and renew the wildcard cert via DNS-01. Writes the cert to `acme.json`.

Service discovery uses two providers in parallel:

- **Docker provider** — any container on the `web` Docker network with `traefik.enable=true` labels gets auto-registered. Fast path for services that run on the Traefik VM itself.
- **File provider** — `dynamic.yml` is watched (`--providers.file.watch=true`) and reloaded within seconds of edit. Used for services that aren't containers Traefik can see (Proxmox UI, off-host Docker hosts, future k8s MetalLB IPs).

### Config delivery — command-line flags, not `traefik.yml`

Static configuration (entrypoints, providers, ACME resolver, log level) is passed as CLI flags in the docker-compose `command:` block, not via a mounted `traefik.yml` file.

Two reasons:

1. It's the pattern the official v3.6 docs recommend. The config is inline with the container definition — one place to look.
2. During bring-up, Traefik's behavior with a mounted `traefik.yml` was inconsistent on v3.6: config was sometimes loaded, sometimes silently ignored, and the container would log nothing when it was the latter. Moving to `command:` flags made the behavior predictable.

### Dashboard — behind basicauth on HTTPS only

The Traefik dashboard is exposed at `https://traefik.lab.hezebonica.ca`, gated by a basicauth middleware defined in `dynamic.yml`. There is no unauthenticated HTTP surface:

- Port 80 redirects to HTTPS
- Port 8080 (the legacy "insecure" API) is not bound
- The `--api.insecure=true` flag is **off**
- The HTTPS dashboard uses `api@internal` as its service, with `dashboard-auth@file` as its middleware

Early in bring-up, `--api.insecure=true` was enabled for diagnostics (querying the API at `http://localhost:8080/api/http/routers`). It was removed during the cleanup step.

## Let's Encrypt + Cloudflare: the cert-issuance flow

The sequence every ~60 days (30 days before expiry, automatically):

```
 1. Traefik checks acme.json — cert valid and >30d left? → skip.
    Otherwise:
 2. Traefik's ACME client contacts https://acme-v02.api.letsencrypt.org/directory
 3. ACME client registers the account (first time only) or uses the existing
    registration from acme.json
 4. ACME client submits a new order for:
    [main: "lab.hezebonica.ca", sans: ["*.lab.hezebonica.ca"]]
 5. Let's Encrypt returns a DNS-01 challenge:
    "Write TXT record _acme-challenge.lab.hezebonica.ca = <token>"
 6. ACME client calls Cloudflare API with the scoped token:
    POST /zones/<zone>/dns_records { type: TXT, name: _acme-challenge..., content: <token> }
 7. ACME client polls Cloudflare until the record is propagated, then tells
    Let's Encrypt "check it now"
 8. Let's Encrypt queries public DNS for the TXT record (via 1.1.1.1 / 8.8.8.8,
    configured in the resolver list to avoid caching surprises)
 9. TXT record validates → LE issues the cert and signs it
10. ACME client cleans up the TXT record on Cloudflare
11. Traefik writes the cert + private key into acme.json (chmod 600)
12. Traefik hot-loads the new cert; subsequent TLS handshakes serve it
```

The entire flow takes 30–90 seconds end-to-end, happens in the background, and requires no manual intervention. The only way it can fail in normal operation is:

- Cloudflare API token expired or revoked → rotate the token, Traefik retries
- Let's Encrypt rate limits hit → unlikely given one cert per ~60 days
- Cloudflare outage → retry when it's back

### Why DNS-01 specifically cares about Cloudflare's resolvers

Traefik's ACME client is configured with:

```
--certificatesresolvers.cloudflare.acme.dnschallenge.resolvers=1.1.1.1:53,8.8.8.8:53
```

This tells the client **which DNS servers to use for checking propagation**, not which provider to write to. Some ISPs run caching resolvers that can return stale responses, causing ACME to believe the TXT record isn't there when it actually is. Pointing the propagation check at public resolvers side-steps that.

### The challenge record never touches LAN DNS

Pi-hole has no role in cert issuance. The TXT record (`_acme-challenge.lab.hezebonica.ca`) lives only on Cloudflare's authoritative DNS, where Let's Encrypt queries it. LAN clients never see it, don't need to resolve it, and Pi-hole doesn't serve it.

## Traefik <-> upstream service patterns

### Pattern A — container on the Traefik VM with labels

```yaml
services:
  grafana:
    image: grafana/grafana:latest
    networks: [web]
    labels:
      - traefik.enable=true
      - traefik.http.routers.grafana.rule=Host(`grafana.lab.hezebonica.ca`)
      - traefik.http.routers.grafana.entrypoints=websecure
      - traefik.http.routers.grafana.tls.certresolver=cloudflare
      - traefik.http.services.grafana.loadbalancer.server.port=3000
```

Traefik's Docker provider picks up the labels within seconds. No DNS change — the Pi-hole wildcard already covers `grafana.lab.hezebonica.ca`. No cert change — the wildcard covers it.

### Pattern B — off-host service via file provider

```yaml
# dynamic.yml
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

`insecureSkipVerify: true` is acceptable on LAN: TLS between client and Traefik is fully verified; the Traefik → upstream leg is inside the same subnet and the upstream's self-signed cert is a known quantity.

### Future — k8s services via MetalLB IPs

The k8s cluster (`devops-cluster-architecture.md`) will expose services via MetalLB in the `192.168.57.100–.120` range. Each one gets a file-provider entry like Pattern B but pointing at the MetalLB IP. The edge Traefik stays the single TLS boundary.

## Security posture

| Concern | Mitigation |
|---|---|
| Cloudflare API token leak | Token is scoped to `Zone:DNS:Edit` on only `hezebonica.ca`. Can be revoked independently from the main Cloudflare account. Lives in `.env` (mode 600, gitignored). |
| `acme.json` contains the private key | Enforced `chmod 600`; Traefik refuses looser permissions and will exit on startup. Directory is not in git. |
| Dashboard access | Basicauth on the HTTPS router. No unauthenticated endpoint. HTTP redirects to HTTPS. |
| Upstream exposure to internet | None. No NAT, no tunnel. Public DNS has no A records for `*.lab.hezebonica.ca`. |
| Trust in Cloudflare | Accepted. They see domain ownership and authoritative DNS, but not service traffic. |
| Trust in Let's Encrypt | Accepted. They see certificate requests; cert transparency logs are public anyway. |
| Dashboard port 8080 | Unbound. Removed during cleanup. |

## Known operational characteristics

- **Auto-renewal**: Traefik checks certs at startup and every 24h after. Renews 30 days before expiry. No cron, no manual step.
- **Restart on Docker/Traefik updates**: A routine `docker compose pull && docker compose up -d` on the VM picks up new images. Takes ~15 seconds of downtime. Certs in `acme.json` persist across restarts.
- **Disaster recovery**: If the VM is lost, `terraform apply` rebuilds it from scratch in ~5 minutes. Re-running Traefik will re-issue the wildcard from Let's Encrypt. Nothing else to restore unless you want to preserve the existing cert (back up `acme.json`).
- **Config changes**: `dynamic.yml` is hot-reloaded. `docker-compose.yml` `command:` changes require `docker compose up -d --force-recreate`.

## Consciously-accepted trade-offs

| Trade-off | Accepted because |
|---|---|
| WAN dependency for cert issuance (not for normal operation) | Only bites on issuance/renewal (~every 60 days). If WAN is down that day, cert starts getting close to expiry but still works; Traefik retries. |
| Single Traefik VM = single point of failure for ingress | At homelab scale, recovery is 5 min. HA would add Keepalived/VRRP complexity for a problem that's never bitten. |
| All services share one wildcard cert's identity | If the cert is compromised, every service needs re-issuance. `acme.json` permissions + VM isolation make this low-probability. |
| Cloudflare DNS dependency | Trust is scoped: Cloudflare can observe zone changes (which domains exist) but not service traffic. |
| Pi-hole on Firewalla — config lives under `/home/pi/.firewalla/run/` | Firewalla firmware updates may rebuild `run/` state. The one-line dnsmasq config is trivial to re-add; recovery procedure in [`tls-everywhere-runbook.md`](./tls-everywhere-runbook.md). |

## What this setup does NOT do

- **Does not** expose any service to the public internet
- **Does not** run its own CA — LE is the authority
- **Does not** require clients to install custom CA certificates
- **Does not** handle authentication for upstream services — that's each service's problem (or a future forward-auth layer like Authelia)
- **Does not** provide observability — that comes with the k8s cluster + Grafana Alloy → Grafana Cloud

## Pointers

- **Project overview**: [`README.md`](./README.md)
- **Bring-up runbook**: [`tls-everywhere-runbook.md`](./tls-everywhere-runbook.md)
- **VM Terraform module**: `terraform/traefik-vm/`
- **Next milestone**: [`devops-cluster-architecture.md`](./devops-cluster-architecture.md)
