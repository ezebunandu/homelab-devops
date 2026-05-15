# Homelab — a paved path for self-hosted experiments

A reproducible, IaC-managed home Proxmox cluster built for one purpose: making it easy to try, deploy, and operate self-hosted services without giving up the security controls you'd expect in production.

The cluster itself is plumbing. The point is that **dropping a new app onto this lab feels like dropping it onto a real platform** — real TLS, real CI/CD pipeline, real image registry, real secret management, real GitOps. Experimenting is cheap because the boring parts are already solved.

## What this gets you

| Capability | What it looks like in practice |
|---|---|
| **Real TLS on every internal service** | A new `*.lab.hezebonica.ca` hostname routes through Traefik with a wildcard Let's Encrypt cert. No internal CA to distribute, no self-signed warnings. |
| **CI/CD with security gates** | Code → build (Kaniko) → scan (Trivy, blocks HIGH/CRITICAL) → promote to Harbor → deploy via ArgoCD. A failing gate stops the pipeline; no opt-out. |
| **GitOps everywhere** | ArgoCD reconciles the platform from a single repo (`homelab-platform`). App-of-apps pattern; Helm for vendor charts; jsonnet/tanka for first-party config. |
| **Centralized secrets** | Vault HA-Raft in-cluster, consumed by workloads through external-secrets-operator. No secrets in Git, ever. |
| **Supply-chain hygiene** | Renovate proposes dep bumps with a 7-day stability window before any release is eligible for auto-merge. Major bumps to blast-radius components (Talos, k8s, Cilium, ArgoCD) require manual review. |
| **Hardware-refresh proven** | Infrastructure is reproducible from Terraform; nodes can be swapped in place. Demonstrated May 2026 — the `devops` PVE host was upgraded from a Dell T3600 to a Minisforum MS-A2 without data loss or cluster reconstitution. |

## The "drop a new app here" workflow

Adding a new internal service is the five-minute path:

1. Write the app, push to GitLab.
2. CI builds → scans → promotes the image to Harbor.
3. Reference the new image in a Helm values file in the gitops repo.
4. ArgoCD picks up the change, deploys, gets a MetalLB IP.
5. Drop a route file in `~/traefik/dynamic.d/` on the edge VM.
6. Done — `https://newapp.lab.hezebonica.ca` is live with the wildcard cert.

Steps 1–4 are pure GitOps. Step 5 is the one current manual step (route helper scripts exist for batches, e.g. `scripts/traefik-add-pve-prod-cluster.sh`).

## Operating principles

- **One paved path, no exceptions.** A new service goes through CI → scan → Harbor → ArgoCD → Traefik. No backdoor `docker run` on the host.
- **Vendor charts untouched, first-party config in jsonnet.** Don't fork Helm charts; configure them via values.
- **WAN only for control-plane.** Cert issuance and observability telemetry cross the WAN; service traffic never does.
- **Supply-chain patience.** 7-day release-age gate on automated deps; major bumps to blast-radius components always manual.
- **Reproducible everything.** Every VM, every cluster node, every Alloy install, every PVE storage layout — Terraform or scripts in this repo. State in Git or recoverable from the cluster itself.
- **Manual unseal for secret stores.** No auto-unseal key on disk in the lab tier; sealed Vault after a node reboot is acceptable downtime cost.
- **Hardware can change underneath the platform.** The lab is the IaC + state, not the boxes. Hosts get swapped in place when they need to.

## What this is *not*

- **Not a multi-tenant platform.** Built for one user; ACLs assume good faith inside the LAN.
- **Not yet production-ready for home automation.** A separate production cluster on different hardware (planned) will host home-automation workloads and pull images + secrets from this lab.
- **Not self-replicating.** Disaster recovery currently relies on Terraform state + Vault snapshots + unseal keys held outside the lab. Velero is on the list, not yet wired up.

## Key variables

| Variable | Value | Notes |
|---|---|---|
| LAN | `192.168.57.0/24` | Flat LAN, no VLANs |
| Public domain | `hezebonica.ca` | Cloudflare Registrar |
| Internal subdomain | `*.lab.hezebonica.ca` | All LAN services |
| Edge proxy | Traefik VM @ `192.168.57.8` | Debian 12; wildcard LE cert |
| Internal DNS | Pi-hole @ `172.16.0.2` | Split-horizon |
| ACME email | `sam.ezebunandu@gmail.com` | Renewal notices |

### Hardware

| PVE node | Hardware | Role |
|---|---|---|
| `devops` (192.168.57.7) | Minisforum MS-A2 — Ryzen 9 8945HX, 64 GB DDR5, 1 TB NVMe | Carries the bulk of workloads via the fat worker |
| `devops2` (192.168.57.9) | Intel i5-7500T, 32 GB | Slim worker + 1 CP |
| `devops3` (192.168.57.10) | Intel i5-7500T, 32 GB | Slim worker + 1 CP |

The asymmetric topology is deliberate: the MS-A2 carries most of the workload weight via a "fat worker" Talos VM (`talos-04` — 8 vCPU / 28 GB); the smaller PVE nodes anchor Longhorn replicas across separate physical failure domains.

## Topology at a glance

```
Public internet
  Cloudflare DNS  ◄── ACME DNS-01 only (cert issuance)
────────────────────────────────────────────────────────
Home LAN (192.168.57.0/24)
  LAN clients
    │ DNS via Pi-hole — *.lab.hezebonica.ca → 192.168.57.8
    ▼
  Traefik VM (192.168.57.8) — edge TLS termination
    │
    ├─► Proxmox UI
    ├─► Docker services on the Traefik VM itself
    └─► DevOps k8s cluster via MetalLB (192.168.57.100–.120)
          └── 3 Talos CP + 3 Talos workers across 3 PVE hosts
              (1 fat worker on MS-A2 for heavy pods;
               2 slim workers elsewhere for Longhorn anti-affinity)
              kube API VIP @ 192.168.57.30 (currently bypassed → talos-02)
```

## Component status

| Component | Status | Notes |
|---|---|---|
| Edge TLS / Traefik | ✅ Live | Wildcard cert renews via Cloudflare DNS-01 |
| Proxmox cluster | ✅ Live | 3 nodes, quorate |
| Talos K8s cluster | ✅ Live | 6 nodes (3CP+3W), Cilium CNI, MetalLB |
| Longhorn | ⚠ Live, capacity-constrained | Harbor PVC degraded at 2/3 replicas — CP-toleration gap stranding ~300 GB of disk |
| ArgoCD (GitOps) | ✅ Live | App-of-apps from `homelab-platform` (GitHub for now) |
| Vault | ✅ Live | 3-replica HA-Raft, manual unseal |
| Harbor | ⚠ Deployed | Storage-degraded (see Longhorn) |
| GitLab + Runner | 🟡 Planned (DC-6/7) | Self-hosted; replaces GitHub for `homelab-platform` once live |
| Renovate | 🟡 Planned (DC-10) | Scheduled GitLab pipeline, 7-day stability window |
| PVE-host observability | 🟡 Planned (greenfield) | Host metrics + journald → Grafana Cloud via PVE 9's native OTLP push to a local Alloy. Terraform drafted; never applied. **First observability work to land.** |
| In-cluster K8s observability | ❌ Separately broken, separately scoped | Existing Alloy DaemonSet stuck `0/2 ContainerCreating` since deployment. **Different project from PVE-host observability** — separate config, separate scrape targets (kube-state-metrics, cAdvisor, pod logs), separate cost profile against the Grafana Cloud free tier. Tackled after PVE-host observability and GitLab are live. |
| Tailscale (zero-trust remote access) | 🟡 Planned (greenfield) | Terraform drafted; never applied |
| Backups | 🟡 Partial | Per-VM `vzdump`, data-level `scripts/traefik-backup.sh`. No Velero yet. |

## Active and near-term work

In priority order:

1. **Tailscale rollout** — provision Vault secret, apply `terraform/tailscale/`, approve subnet route. ~2 hours. Useful as a precondition for the next items (remote debugging when something acts up).
2. **PVE-host observability** — redesign `terraform/pve-observability/` against PVE 9's native OTLP metric server, push to Grafana Cloud. Greenfield since the original draft was never applied. ~1 day.
3. **GitLab + Runner** (DC-6/7) — deploy via Helm, MetalLB IP `.102`, Traefik route, migrate `homelab-platform` repo from GitHub to in-lab GitLab. Unblocks Renovate (DC-10) and the full CI → Harbor → ArgoCD loop running on self-hosted infrastructure.
4. **Stabilize Longhorn capacity** — add CP-toleration to Longhorn's `instance-manager` DaemonSet, unstrand the 300 GB of CP-attached Longhorn disks. Restores Harbor to 3/3 replicas. Can be picked up in parallel with any of the above.
5. **Talos node resizes** — post-MS-A2-migration follow-up: bump `talos-02`/`talos-03` CPs to 12 GB, `talos-05`/`talos-06` workers to 16 GB. One-at-a-time maintenance.
6. **In-cluster K8s observability** (separate from #2) — rebuild the broken Alloy DaemonSet, this time with metric/log allowlists scoped to fit the Grafana Cloud free tier. Sequenced after GitLab so the lab is observable end-to-end when first-party workloads start landing.

## Backlog — picked up as cycles allow

Smaller items captured during the MS-A2 migration that aren't blocking but shouldn't get forgotten:

- **Automate Talos image staging on PVE nodes** — add a `proxmox_virtual_environment_download_file` resource to `terraform/talos-cluster/` so the Talos cloud image is on every PVE node automatically. Currently has to be `scp`'d manually when a node is rebuilt or added. Pattern exists in `terraform/traefik-vm/main.tf` (`resource "proxmox_virtual_environment_download_file" "debian_12"`).
- **Implement workload-tier scheduling hints** — without `workload-tier=heavy` labels + soft `nodeAffinity`, the scheduler may place heavy pods (GitLab, Harbor) on slim workers when capacity is tight, defeating the asymmetric topology. Label `talos-04` as `heavy`, tag the others `storage`, optionally taint slim workers `PreferNoSchedule`.
- **Tiered Longhorn StorageClasses** — add a `longhorn-fast` class with `numberOfReplicas: 1` pinned to MS-A2 via `diskSelector` for ephemeral/scratch volumes (CI caches, build scratch). Keep `longhorn-ha` (`numberOfReplicas: 3`) as the default. Lets ephemeral data exploit MS-A2's NVMe without paying the 3-replica HA cost.
- **MS-A2 M.2 slot 2 expansion** — the MS-A2 has 3 M.2 slots; only one is currently populated. Adding a 2–4 TB drive in slot 2 and dedicating it to Longhorn data (separate from VM system disks) would isolate rebuild I/O and unblock the in-cluster observability and any future workloads that need real storage. Currently deferred (cost).

## Beyond M2

- Production cluster on separate hardware: pulls images from Harbor, reads secrets from Vault via external-secrets, runs its own ArgoCD against the same gitops repo
- Forward auth in front of sensitive dashboards (Tailscale Serve or Pocket ID)
- Dedicated NAS as Longhorn backup target + Harbor blob storage
- Cloudflare Tunnel for the few services that genuinely should be internet-reachable (webhook receivers, status pages)
- Velero for cluster-wide backup/restore
- Dedicated observability cluster for blast-radius isolation
- IPv6 entrypoints once the LAN supports it

## Repo layout

```
homelab-devops/
├── README.md                       this doc — project overview
├── tls-everywhere-architecture.md  M1 design
├── tls-everywhere-runbook.md       M1 bring-up procedure
├── devops-cluster-architecture.md  M2 design (live) — operations notes section captures lessons from the May 2026 MS-A2 hardware refresh
├── terraform/
│   ├── traefik-vm/                 M1 — edge VM
│   ├── talos-cluster/              M2 — 6-node Talos cluster
│   ├── pve-observability/          M2 — Alloy on PVE hosts (drafted; not yet applied — see active work)
│   ├── tailscale/                  M2 — Tailscale (drafted; not yet applied)
│   └── scratch-vm/                 ad-hoc scratch VM for one-off experiments
└── scripts/
    ├── proxmox-setup.sh            PVE-side Terraform prep
    ├── proxmox-storage-setup.sh    PVE storage prep (legacy T3600 layout — kept for reference)
    ├── pihole-wildcard.sh          split-horizon DNS record
    ├── traefik-setup.sh            Traefik bring-up on the VM
    ├── traefik-add-pve-prod-cluster.sh  add routes for the prod PVE cluster
    └── traefik-backup.sh           extract Traefik state (acme.json, dynamic.d/, .env) off the VM
```
