# Homelab Makeover

Rebuilding a home Proxmox host into a self-hosted DevOps platform: real TLS on every LAN service, IaC-provisioned infrastructure, GitOps-managed workloads, and a path to a separate production cluster for home-automation services.

## Goals

- **Real TLS on every LAN service** — no self-signed warnings, no internal CA to distribute
- **LAN stays LAN** — no service exposed to the public internet; only DNS records and cert-validation TXT records touch the outside world
- **Infrastructure as code** — every VM reproducible from Terraform; cluster workloads reproducible from GitOps
- **GitOps control plane** — ArgoCD + jsonnet/tanka for first-party config; Helm for vendor charts
- **Supply-chain conscious** — automated dependency updates with a 7-day stability window
- **Low ongoing maintenance** — a homelab shouldn't need weekly attention

## Key variables

| Variable | Value | Notes |
|---|---|---|
| Proxmox node | `devops` @ `192.168.57.7` | Dell T3600, PVE 9.1.1 |
| LAN | `192.168.57.0/24` | Flat LAN, no VLANs |
| Public domain | `hezebonica.ca` | Registered with Cloudflare Registrar |
| Internal subdomain | `lab.hezebonica.ca` | All LAN services live here |
| Edge proxy | Traefik VM @ `192.168.57.8` | Wildcard Let's Encrypt cert |
| Internal DNS | Pi-hole @ `172.16.0.2` | Existing container; wildcard for `*.lab.hezebonica.ca` |
| ACME email | `sam.ezebunandu@gmail.com` | Renewal/revocation notices |

## High-level shape

```
Public internet
  Cloudflare DNS  ◄── ACME DNS-01 TXT records (cert issuance only)
────────────────────────────────────────────────────────────────
Home LAN (192.168.57.0/24)
  LAN clients
    │ DNS via Pi-hole — *.lab.hezebonica.ca → 192.168.57.8
    ▼
  Traefik VM (192.168.57.8) — edge TLS termination
    │
    ├─► Proxmox UI
    ├─► services on the Traefik VM itself (labeled Docker)
    └─► DevOps k8s cluster via MetalLB IPs (future)
          └── talos-01..03 @ 192.168.57.20..22, kube API VIP @ .30
```

## Milestones

### M1 — TLS Everywhere (done, 2026-04-21)

Wildcard Let's Encrypt cert at the edge Traefik VM, split-horizon DNS via Pi-hole, Proxmox UI migrated as the first service.

- Design: [`tls-everywhere-architecture.md`](./tls-everywhere-architecture.md)
- Runbook: [`tls-everywhere-runbook.md`](./tls-everywhere-runbook.md)

### M2 — DevOps Kubernetes cluster (next)

3-node Talos cluster on the same Proxmox host, hosting GitLab, Vault, Harbor, ArgoCD, Grafana Alloy, and Renovate (scheduled pipeline for automated dependency updates).

Design: [`devops-cluster-architecture.md`](./devops-cluster-architecture.md).

Sub-milestones:

**Pre-requisite (before DC-3):**
- [ ] Shrink Firewalla DHCP pool to exclude MetalLB's `192.168.57.100–.120` range (or reserve that block as static). Prevents DHCP leases colliding with LoadBalancer IPs.

- [ ] **DC-1** — Terraform module for 3 Talos VMs (`terraform/talos-cluster/`)
- [ ] **DC-2** — Talos machine configs + kube-vip API VIP at `192.168.57.30`
- [ ] **DC-3** — Install Cilium, MetalLB, Longhorn, ArgoCD (imperative bootstrap)
- [ ] **DC-4** — GitOps repo scaffold (tanka + jsonnet + argocd-app helper)
- [ ] **DC-5** — Deploy Vault → unseal → wire external-secrets backend
- [ ] **DC-6** — Deploy Harbor, GitLab, GitLab Runners
- [ ] **DC-7** — Deploy Grafana Alloy; verify telemetry reaches Grafana Cloud
- [ ] **DC-8** — Add edge Traefik routes for each service (gitlab, harbor, vault, argocd)
- [ ] **DC-9** — Production cluster coupling: Harbor pull creds, Vault k8s auth, prod ArgoCD scope
- [ ] **DC-10** — Renovate scheduled pipeline + `renovate.json` with 7-day stability window and auto-merge policy

### Beyond M2

- Production cluster on separate hardware for home-automation workloads (pulls from Harbor, reads Vault via external-secrets, runs its own ArgoCD against the same gitops repo)
- Forward auth in front of sensitive dashboards (Authelia, Pocket ID, or Tailscale Serve)
- Dedicated NAS as Longhorn backup target + Harbor blob storage
- Separate `ext.hezebonica.ca` zone + Cloudflare Tunnel for services that should be internet-reachable
- Velero for cluster-wide backup/restore
- Dedicated observability cluster for blast-radius isolation
- IPv6 entrypoints once the LAN supports it

## Repo layout

```
homelab-devops/
├── README.md                        this doc — project overview
├── tls-everywhere-architecture.md   M1 design
├── tls-everywhere-runbook.md        M1 bring-up procedure
├── devops-cluster-architecture.md   M2 design
├── terraform/
│   └── traefik-vm/                  M1 — edge VM (bpg/proxmox)
└── scripts/
    ├── proxmox-setup.sh             PVE-side prep for Terraform
    ├── pihole-wildcard.sh           split-horizon DNS record
    └── traefik-setup.sh             Traefik bring-up on the VM
```

## Operating principles

- **Centralize where it pays**: single edge proxy, single wildcard cert, single GitOps repo across clusters. Divergence costs more than it saves at this scale.
- **Vendor charts untouched, first-party config in jsonnet**: Helm for GitLab/Harbor/Vault/etc.; tanka + jsonnet for our own workloads and per-env tweaks.
- **WAN only for control-plane**: cert issuance and Grafana Cloud telemetry cross the WAN; service traffic never does.
- **Supply-chain patience**: 7-day release-age gate on automated dep updates; major bumps for Talos/k8s/Cilium/ArgoCD always manual.
