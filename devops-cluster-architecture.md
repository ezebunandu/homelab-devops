# DevOps Cluster Architecture — Talos Kubernetes on Proxmox

## Goal

Stand up a Kubernetes cluster (Talos Linux nodes on Proxmox VMs) hosting the homelab's DevOps tooling: git + CI (GitLab), secrets (Vault), container registry (Harbor), GitOps controller (ArgoCD), and observability shipping (Grafana Alloy → Grafana Cloud).

This cluster is the **management plane** for a separate production cluster running home-automation workloads on different hardware on a different subnet. That prod cluster pulls images from Harbor, reads secrets from Vault, and runs its own ArgoCD against the same GitOps repo.

## Relationship to M1 (TLS Everywhere)

Prereqs delivered by M1 (see [`README.md`](./README.md)):
- Working wildcard DNS (`*.lab.hezebonica.ca` → Traefik VM at `192.168.57.8`)
- Valid Let's Encrypt wildcard cert at the edge
- Proxmox node + Terraform credentials (`terraform@pve` token, passwordless SSH)

This doc is M2 — it assumes M1 is complete.

## Decisions locked in (2026-04-20, updated 2026-05-03)

| Decision | Choice | Rationale |
|---|---|---|
| Cluster topology | 3CP + 3W across 3 Proxmox hosts | Spreads failure domains across 3 physical machines; dedicated workers free CPs for etcd |
| Node OS | Talos Linux | Immutable, API-driven, minimal attack surface |
| CNI | Cilium | NetworkPolicy + L7 observability + eBPF |
| Kube API VIP | Talos native L2 VIP | Built-in to Talos; no extra static pod required |
| Service LoadBalancer | MetalLB (L2 mode) | Works on any flat LAN |
| Storage | Longhorn (3 replicas) | Distributed block, survives 1-node loss |
| Ingress | Traefik VM stays as edge | Shared front door for k8s + non-k8s services |
| Deployment model | Jsonnet/Tanka (first-party) + Helm (third-party) | DRY where it pays; don't re-author vendor charts |
| Config language | Jsonnet everywhere — no YAML in source | Consistency; real programming language |
| GitOps controller | ArgoCD, per-cluster, one shared repo | No cross-cluster auth gymnastics |
| Observability | Grafana Alloy → Grafana Cloud | Saves ~8 GB RAM + ops burden; WAN dep accepted |
| Secrets | Vault in-cluster, manual unseal | Standard homelab pattern |
| Image promotion | `crane copy` in GitLab CI (push-based) | CI stays the source of truth |
| Dependency automation | Renovate via GitLab CI scheduled pipeline, 7-day stability window | Reuses runner infra; supply-chain hygiene |

## Cluster topology

```
Proxmox cluster (devops-cluster)
├── devops    (192.168.57.7)   Minisforum MS-A2, Ryzen 9 8945HX (16C/32T), 64 GB DDR5, 1 TB NVMe
│   ├── traefik   192.168.57.8    edge proxy
│   ├── talos-01  192.168.57.20   control plane
│   └── talos-04  192.168.57.23   worker (fat — heavy pods land here)
├── devops2   (192.168.57.9)   Intel i5-7500T, 4 vCPU, 32 GB
│   ├── talos-02  192.168.57.21   control plane
│   └── talos-05  192.168.57.24   worker (slim)
└── devops3   (192.168.57.10)  Intel i5-7500T, 4 vCPU, 32 GB
    ├── talos-03  192.168.57.22   control plane
    └── talos-06  192.168.57.25   worker (slim)

kube API VIP   192.168.57.30   Talos L2 VIP (floats across CPs)
```

`kubectl` targets `https://192.168.57.30:6443` — doesn't care which CP node is up. VIP is currently blocked by Firewalla so `kubectl` points at `192.168.57.21` (talos-02) directly in the interim. (Originally `.20`/talos-01, repointed during the MS-A2 hardware swap to a CP that wouldn't go offline.)

### Hardware refresh — May 2026

`devops` was originally a Dell T3600 (8 vCPU Xeon, 64 GB DDR3, mixed HDD+SSD storage). Swapped in-place for the Minisforum MS-A2 in May 2026 while preserving IP, hostname, cluster membership, and all running workloads. `devops2`/`devops3` RAM upgraded from 15.5 GB → 32 GB ahead of the swap. Lessons learned during the swap are captured in the [Operations notes](#operations-notes--hard-won-lessons) section below.

Notable changes vs the original M2 design:
- **Storage**: single 1 TB NVMe on `devops` (no `local-ssd` tier). Both `os_pool` and `data_pool` on `devops` now use `local-lvm`.
- **Asymmetric workers**: `talos-04` resized to 8 vCPU / 28 GB to absorb heavy pods (Vault, Harbor, GitLab, ArgoCD); `talos-05`/`talos-06` remain at 2 vCPU / 7 GB pending a planned post-migration resize to 16 GB.
- **CP-toleration gap discovered**: Longhorn `instance-manager` DaemonSet doesn't tolerate the CP `NoSchedule` taint, so the 100 GB CP data disks (300 GB total) are stranded. Tracked as open work; Harbor's `harbor-registry` PVC is at 2/3 replica health as a direct consequence.

## Node specs

**Control plane nodes (talos-01/02/03):**

| Resource | talos-01 (on `devops` / MS-A2) | talos-02 / talos-03 (on `devops2` / `devops3`) |
|---|---|---|
| vCPU | 4 | 2 |
| RAM | 8 GB | 8 GB (resize to 12 GB pending — hardware now supports it) |
| Root disk | 32 GB (scsi0) — Talos system | 32 GB (scsi0) — Talos system |
| Data disk | 100 GB (scsi1) — Longhorn replica (currently stranded; see CP-toleration gap above) | 100 GB (scsi1) — Longhorn replica (stranded) |
| Network | single NIC on `vmbr0`, static IP | single NIC on `vmbr0`, static IP |
| Firmware | SeaBIOS | SeaBIOS |
| Machine type | q35 | q35 |
| SCSI controller | virtio-scsi-single | virtio-scsi-single |

`allowSchedulingOnControlPlanes: false` — no workloads run on CP nodes.

**Worker nodes (talos-04/05/06):**

| Resource | talos-04 (on `devops` / MS-A2 — fat) | talos-05 / talos-06 (on `devops2` / `devops3` — slim) |
|---|---|---|
| vCPU | 8 | 2 |
| RAM | 28 GB | 7 GB (resize to 16 GB pending) |
| Root disk | 32 GB (scsi0) — Talos system | 32 GB (scsi0) — Talos system |
| Data disk | 200 GB (scsi1) — Longhorn replica | 200 GB (scsi1) — Longhorn replica |
| Network | single NIC on `vmbr0`, static IP | single NIC on `vmbr0`, static IP |
| Firmware | SeaBIOS | SeaBIOS |
| Machine type | q35 | q35 |
| SCSI controller | virtio-scsi-single | virtio-scsi-single |

Cluster totals (current): **18 vCPU, 66 GB RAM**, ~1.4 TB storage committed to k8s. After the pending slim-worker + CP RAM resizes: **18 vCPU, 82 GB RAM**.

The asymmetric worker sizing is deliberate: `talos-04` on the MS-A2 has the headroom to host GitLab + Harbor + ArgoCD + one Vault replica + bursts; the slim workers on `devops2`/`devops3` exist primarily to hold Longhorn replicas in different physical failure domains, with capacity for light pods. Scheduling spreads via soft `nodeAffinity` for `workload-tier=heavy` on `talos-04` is **pending** (open-work item — without it the scheduler may place heavy pods on slim workers when capacity is tight).

## Network layout

| Range | Purpose |
|---|---|
| `192.168.57.0/24` | Existing LAN; all VMs here |
| `192.168.57.30` | kube API VIP (Talos native L2 VIP) |
| `192.168.57.100–.120` | MetalLB L2 pool (21 LoadBalancer IPs) |
| `10.42.0.0/16` | Pod CIDR (Cilium default) |
| `10.43.0.0/16` | Service CIDR (Cilium default) |

Production cluster on a different subnet — no CIDR collisions. Inter-subnet routing exists at the home router; image pulls and Vault auth traverse it.

## MetalLB IP allocations

| Service | IP |
|---|---|
| ArgoCD | 192.168.57.100 |
| Harbor | 192.168.57.101 |
| GitLab | 192.168.57.102 |
| Vault | 192.168.57.103 |
| (reserved) | 192.168.57.104–.120 |

**Note:** this range overlaps Firewalla's default DHCP pool. Before DC-3, shrink Firewalla's DHCP allocation to start at `.121` (or statically reserve `.100–.120`) so DHCP leases can't collide with LoadBalancer IPs.

## Stack + namespace layout

```
kube-system        cilium, coredns, metrics-server
metallb-system     metallb
longhorn-system    longhorn
argocd             argocd (syncs everything below)
cert-manager       cert-manager (optional in edge-TLS topology)
external-secrets   external-secrets-operator → vault backend
observability      grafana-alloy (ships to Grafana Cloud)
vault              vault (3 replicas, raft, manual unseal)
registry           harbor
gitlab             gitlab + its MinIO
gitlab-runners     gitlab-runner (k8s executor, spawns per-job pods)
```

## RAM budget

| Namespace / workload | RAM |
|---|---|
| kube-system + CNI | 2 GB |
| Longhorn | 3 GB |
| MetalLB | 0.2 GB |
| ArgoCD | 1 GB |
| cert-manager, external-secrets | 0.5 GB |
| Grafana Alloy | 1 GB |
| Vault | 2 GB |
| Harbor | 6 GB |
| GitLab + MinIO | 10 GB |
| GitLab Runner (idle) | 1 GB |
| Overhead / burst | 5 GB |
| **Committed** | **~31 GB** |
| **Cluster budget (current: 66 GB)** | **~35 GB headroom** post-MS-A2 swap |
| **Cluster budget (after pending CP+slim-worker resizes: 82 GB)** | ~51 GB headroom |

## Edge integration — Traefik VM stays

LAN DNS wildcard `*.lab.hezebonica.ca` already points at `192.168.57.8`. Traefik's file provider routes each cluster service to its MetalLB IP:

```yaml
# ~/traefik/dynamic.d/30-k8s-services.yml on the edge VM
http:
  routers:
    gitlab:
      rule: "Host(`gitlab.lab.hezebonica.ca`)"
      entryPoints: [websecure]
      service: gitlab
      tls: { certResolver: cloudflare }
    harbor:
      rule: "Host(`harbor.lab.hezebonica.ca`)"
      entryPoints: [websecure]
      service: harbor
      tls: { certResolver: cloudflare }
    # ... argocd, vault, etc.

  services:
    gitlab:
      loadBalancer:
        servers: [{ url: "http://192.168.57.101" }]
    harbor:
      loadBalancer:
        servers: [{ url: "http://192.168.57.102" }]
```

The edge holds the single wildcard cert from Let's Encrypt. K8s services never run ACME. cert-manager in-cluster is optional — only needed for pod-to-pod mTLS.

## Production cluster coupling

Three explicit coupling points:

1. **Image pulls** — prod workloads pull from `harbor.lab.hezebonica.ca`. Harbor robot credentials injected as imagePullSecrets in prod.
2. **Secrets** — prod apps use external-secrets-operator targeting `vault.lab.hezebonica.ca`. Vault's k8s auth trusts prod's ServiceAccount JWTs, configured per namespace.
3. **CI → deploys** — GitLab Runner applies manifests to prod via kubeconfig in Vault, OR commits to the GitOps repo and prod's ArgoCD pulls. Prefer the latter (pure GitOps).

No direct cluster-to-cluster API access beyond HTTPS to Harbor + Vault.

## Deployment model — YAML values + Helm (Jsonnet deferred)

Two paths, chosen per component:

| Component | Tool | Reason |
|---|---|---|
| Vendor charts (GitLab, Harbor, Vault, Longhorn, MetalLB, Cilium, ArgoCD, cert-manager) | Helm via ArgoCD multi-source (`source.chart` + values overlay from `homelab-platform` repo) | Don't re-author vendor charts |
| Grafana Alloy config, per-env tweaks, home-automation workloads | Tanka environments (jsonnet) — deferred until first-party workloads exist | Real templating where it pays |

Platform services use YAML values files in `homelab-platform/apps/<service>/values.yaml`, referenced via ArgoCD's multi-source `$values` ref. Tanka will be introduced when first-party workloads (Alloy config, GitLab Runner) need real templating.

## GitOps repo structure

`homelab-platform` (private GitHub repo, moves to self-hosted GitLab after DC-6):

```
homelab-platform/
├── argocd/
│   ├── projects/
│   │   └── platform.yaml          ArgoCD Project scoping the platform namespace
│   └── apps/
│       ├── root.yaml              App-of-apps root — applied once manually to bootstrap
│       ├── cert-manager.yaml      wave 0
│       ├── external-secrets.yaml  wave 1
│       ├── vault.yaml             wave 2
│       ├── harbor.yaml            wave 3
│       ├── gitlab.yaml            wave 3
│       ├── grafana-alloy.yaml     wave 4
│       └── renovate.yaml          wave 4
├── apps/
│   └── <service>/
│       └── values.yaml            Helm values overlay (referenced via ArgoCD $values ref)
└── scripts/
    └── vault-init.sh              Post-unseal Vault configuration
```

Each `Application` uses ArgoCD multi-source: the upstream Helm chart repo provides the chart; this repo provides the values overlay. Bootstrap:

```bash
kubectl apply -f argocd/projects/platform.yaml
kubectl apply -f argocd/apps/root.yaml
# ArgoCD discovers and syncs all apps in argocd/apps/ automatically
```


## Image promotion contract

GitLab registry → Harbor, push-based in CI:

```yaml
# .gitlab-ci.yml
stages: [build, test, scan, promote]

build:
  stage: build
  image: gcr.io/kaniko-project/executor:latest
  script:
    - /kaniko/executor --context "$CI_PROJECT_DIR"
        --destination "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA"

scan:
  stage: scan
  image: aquasec/trivy:latest
  script:
    - trivy image --exit-code 1 --severity HIGH,CRITICAL
        "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA"

promote:
  stage: promote
  image: gcr.io/go-containerregistry/crane:debug
  script:
    - crane auth login -u "$HARBOR_USER" -p "$HARBOR_PASS" harbor.lab.hezebonica.ca
    - crane copy "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA"
        "harbor.lab.hezebonica.ca/library/$CI_PROJECT_NAME:$CI_COMMIT_SHA"
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
```

Prod only pulls from Harbor. GitLab registry is a CI implementation detail.

## Dependency automation — Renovate

Automated MRs for every pinned version across the homelab: Helm chart `targetRevision` values in jsonnet, jsonnet-bundler deps, Terraform providers, Dockerfile base images, the Traefik VM's compose image, and `.gitlab-ci.yml` image pins.

**Runtime.** Scheduled pipeline on the standard `gitlab-runner` pool — canonical self-hosted Renovate. Reuses runner infra rather than a dedicated CronJob; logs land in GitLab CI alongside every other build. Config lives in the gitops repo (`tools/renovate/` — pipeline + `renovate.json`).

**Auth.** Group-scoped GitLab access token (`api` scope) stored in Vault, injected into the scheduled pipeline via an external-secrets-backed CI variable. No tokens in GitLab's CI/CD settings.

**Stability window.** `minimumReleaseAge: 7 days` applied globally. A new release isn't eligible for an MR until it's been public for a week — supply-chain hygiene against the compromised-package-discovered-within-days pattern. Latency is tolerable at homelab scale.

**Auto-merge policy:**

| Scope | Behavior |
|---|---|
| Patch + minor, generic deps | Auto-merge after CI green (still gated by the 7-day window) |
| Major | MR opened; manual review |
| Talos, Kubernetes core, Cilium, ArgoCD | Manual review always — blast radius |
| Security advisories | Auto-merge regardless of severity; 7-day window still applies |

**Bootstrap.** Stands up after GitLab is live (bootstrap step 13). No hosted-Renovate bridge in the interim — dependency bumps on `homelab-devops` and the gitops repo are manual until then.

## Bootstrap sequence

Imperative bootstrap (Terraform + CLI), then GitOps takes over.

1. ✅ **Provision 6 Talos VMs across 3 Proxmox hosts** — `terraform apply` in `terraform/talos-cluster/`
2. ✅ **Apply machine configs + bootstrap etcd** — handled by `terraform apply` via the Talos provider
3. ✅ **Install Cilium, MetalLB, Longhorn, ArgoCD** — `bash post-apply.sh`; ArgoCD exposed at `https://argocd.lab.hezebonica.ca` via MetalLB IP `192.168.57.100` + Traefik file-provider route
4. ✅ **GitOps repo scaffold** — `homelab-platform` on GitHub; `kubectl apply` of project + root app-of-apps; ArgoCD discovers and syncs all platform apps
5. ✅ **Vault deployed and configured** — HA Raft (3 replicas), manually initialised + unsealed, Kubernetes auth enabled, external-secrets ClusterSecretStore wired (`scripts/vault-init.sh`)
6. ⚠ **Deploy Harbor** — deployed and serving; `harbor-registry` PVC is degraded at 2/3 Longhorn replicas due to the CP-toleration gap (see open work).
7. **Deploy GitLab** — root password from Vault, Longhorn PVCs, MetalLB IP `.102`, Traefik route, migrate `homelab-platform` repo from GitHub
8. **Add remaining Traefik routes** — vault, harbor, gitlab (ArgoCD route already live)
9. **Configure Renovate** — scheduled pipeline + `renovate.json` in the gitops repo; group-scoped GitLab token in Vault

Steps 1–5 complete. Step 6 (Harbor) is deployed but degraded — see open work. Step 7 (GitLab) is next.

> **Hardware refresh interlude (May 2026):** the `devops` PVE host was swapped from a Dell T3600 to a Minisforum MS-A2 mid-bootstrap, between deploying Vault (DC-5) and finishing Harbor/GitLab (DC-6/7). The cluster came through the swap intact with `talos-01` and `talos-04` recreated on the new hardware; no etcd or Vault data was lost. Operational lessons from the swap are captured in the [Operations notes](#operations-notes--hard-won-lessons) section below.

## Open questions / future work

- **Backup strategy** — Velero for k8s resources; Longhorn native backup target (S3 on a future NAS)
- **Harbor blob storage** — start on Longhorn; move to S3/NFS once a NAS exists
- **NAS** — not in scope yet; may appear as a Longhorn backup target + Harbor blob store
- **Autoscaling** — unnecessary at this size
- **Dedicated observability cluster** — blast-radius isolation, long-term consideration
- **Cluster upgrades** — `talosctl upgrade` per node; rehearse before production-critical use
- **Disaster recovery** — etcd snapshots via Talos; Velero for PV/k8s state
- **IP-allocation pre-flight** — an `arping`-based Terraform `data "external"` that fails a plan if the target IP is live on the LAN. Cheap belt-and-braces against static-IP collisions for Talos nodes, kube-vip VIP, and future scratch/service VMs. Firewalla API integration (for visibility into *leased-but-offline* devices + active IP reservation) is strictly heavier; only worth it if we also want reservation semantics. Deferred — revisit if the DHCP-pool shrink (above) ends up not sufficient.

## Operations notes — hard-won lessons

Captured from the MS-A2 hardware refresh (May 2026) and earlier bring-up. Each one cost real time to discover; the next person doing similar work shouldn't have to rediscover them.

### Draining a worker fails on Vault and Longhorn PDBs

With only 3 worker nodes and Vault's hostname-level `podAntiAffinity` requiring 1-per-node, cordoning any worker leaves the displaced Vault pod with nowhere to schedule. Eviction blocks on the Vault PDB indefinitely; the Longhorn `instance-manager` PDB then blocks on the same node because the volume is still attached. Drain hangs.

**Workaround**: before draining a worker, scale Vault to 2 replicas (suspend ArgoCD auto-sync first so it doesn't immediately revert), then drain, then scale back after the new node is in place. Unseal the recreated vault-2 with Shamir shares; re-enable ArgoCD auto-sync.

```bash
kubectl -n argocd patch app vault --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n vault scale statefulset vault --replicas=2
# ... do drain work ...
kubectl -n vault scale statefulset vault --replicas=3
kubectl exec -it -n vault vault-2 -- vault operator unseal   # x3
kubectl -n argocd patch app vault --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

### Longhorn replicas can land on CPs that can't host them

Longhorn's `instance-manager` DaemonSet doesn't tolerate the `node-role.kubernetes.io/control-plane:NoSchedule` taint by default. So although CP nodes have 100 GB Longhorn data disks provisioned (per `terraform/talos-cluster/main.tf`), no instance-manager runs on them — making 300 GB of storage effectively unreachable. Replica scheduling falls back to 3 worker nodes only, which can hit the default 30% reserved-storage threshold quickly. Symptom: `precheck new replica failed: insufficient storage`.

**Fix**: add the CP toleration to Longhorn's `defaultSettings.taintToleration` in Helm values:
```yaml
defaultSettings:
  taintToleration: "node-role.kubernetes.io/control-plane:NoSchedule"
```

### `/etc/pve/priv/known_hosts` doesn't support `ssh-keygen -R`

`/etc/pve` is pmxcfs (FUSE-backed SQLite), which doesn't support hard links. `ssh-keygen -R` creates a `.old` backup via hard-link before rewriting, so it fails with `Operation not permitted`.

**Workaround** — `awk`-filter and overwrite. pmxcfs is cluster-replicated, so editing on one node propagates:
```bash
awk '!/<IP_TO_REMOVE>/ && !/^<HOSTNAME_TO_REMOVE>/' \
  /etc/pve/priv/known_hosts > /tmp/kh.tmp &&
cp /tmp/kh.tmp /etc/pve/priv/known_hosts &&
rm /tmp/kh.tmp
```

### `pvecm add` doesn't fully populate per-node `/root/.ssh/known_hosts`

When a node rejoins a PVE cluster, the cluster-wide `/etc/pve/priv/known_hosts` gets updated, but each surviving node's `/root/.ssh/known_hosts` is per-node and not auto-updated. `ssh`/`scp` between PVE nodes from `root@` then prompts interactively and breaks scripted operations (Terraform SSH provisioners, image staging).

**Fix** — prime explicitly after `pvecm add` (and after any host SSH key rotation):
```bash
ssh root@<surviving-node-ip> 'ssh-keyscan -H <new-node-ip> >> /root/.ssh/known_hosts'
```

### Talos cloud image is not auto-staged on new PVE nodes

`terraform/talos-cluster/` references the Talos image at `local:iso/talos-<schematic-id>-<version>.img` but doesn't include a download resource. On a fresh PVE node, terraform fails with `creating custom disk: ... non-existent or non-regular file`.

**Workaround**: copy from any existing PVE node before applying:
```bash
ssh root@<existing-pve-node> \
  'scp /var/lib/vz/template/iso/talos-*.img root@<new-pve-node>:/var/lib/vz/template/iso/'
```

Tracked as a backlog item in the README — adding a `proxmox_virtual_environment_download_file` resource would close this for good.

### Kubelet/kubectl is hardcoded to one CP IP, not the VIP

`kubeconfig` is rendered with `server: https://192.168.57.30:6443` (the VIP), but Firewalla blocks the L2 VIP traffic. Until the Firewalla rule is fixed, `kubectl` must point at a specific CP IP directly. **Important during host swaps**: that target CP must not be the one being taken down. After removing `talos-01`, repointed to `https://192.168.57.21:6443` (talos-02):

```bash
kubectl config set-cluster devops --server=https://192.168.57.21:6443
```
