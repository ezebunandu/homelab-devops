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
├── devops    (192.168.57.7)   Dell T3600, 8 vCPU, 64 GB
│   ├── traefik   192.168.57.8    edge proxy
│   ├── talos-01  192.168.57.20   control plane
│   └── talos-04  192.168.57.23   worker
├── devops2   (192.168.57.9)   4 vCPU, 15.5 GB
│   ├── talos-02  192.168.57.21   control plane
│   └── talos-05  192.168.57.24   worker
└── devops3   (192.168.57.10)  4 vCPU, 15.5 GB
    ├── talos-03  192.168.57.22   control plane
    └── talos-06  192.168.57.25   worker

kube API VIP   192.168.57.30   Talos L2 VIP (floats across CPs)
```

`kubectl` targets `https://192.168.57.30:6443` — doesn't care which CP node is up. VIP is currently blocked by Firewalla so `kubectl` points at `192.168.57.20` directly in the interim.

## Node specs

**Control plane nodes (talos-01/02/03):**

| Resource | talos-01 | talos-02 / talos-03 |
|---|---|---|
| vCPU | 4 | 2 |
| RAM | 8 GB | 8 GB |
| Root disk | 32 GB (scsi0) — Talos system | 32 GB (scsi0) — Talos system |
| Data disk | 100 GB (scsi1) — Longhorn replica | 100 GB (scsi1) — Longhorn replica |
| Network | single NIC on `vmbr0`, static IP | single NIC on `vmbr0`, static IP |
| Firmware | SeaBIOS | SeaBIOS |
| Machine type | q35 | q35 |
| SCSI controller | virtio-scsi-single | virtio-scsi-single |

`allowSchedulingOnControlPlanes: false` — no workloads run on CP nodes.

**Worker nodes (talos-04/05/06):**

| Resource | talos-04 | talos-05 / talos-06 |
|---|---|---|
| vCPU | 2 | 2 |
| RAM | 8 GB | 7 GB |
| Root disk | 32 GB (scsi0) — Talos system | 32 GB (scsi0) — Talos system |
| Data disk | 200 GB (scsi1) — Longhorn replica | 200 GB (scsi1) — Longhorn replica |
| Network | single NIC on `vmbr0`, static IP | single NIC on `vmbr0`, static IP |
| Firmware | SeaBIOS | SeaBIOS |
| Machine type | q35 | q35 |
| SCSI controller | virtio-scsi-single | virtio-scsi-single |

Cluster totals: 16 vCPU, 47 GB RAM, ~1.4 TB storage committed to k8s.

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
| GitLab | 192.168.57.101 |
| Harbor | 192.168.57.102 |
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
| **Cluster budget (47 GB)** | ~16 GB headroom |

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

## Deployment model — Jsonnet + Helm

Two paths, chosen per component:

| Component | Tool | Reason |
|---|---|---|
| Vendor charts (GitLab, Harbor, Vault, Longhorn, MetalLB, Cilium, ArgoCD, cert-manager) | Helm via ArgoCD `source.chart` | Don't re-author vendor charts |
| Grafana Alloy config, per-env tweaks, your apps, home-automation workloads | Tanka environments (jsonnet) | Real templating where it pays |

Helm values are jsonnet objects passed through ArgoCD's `valuesObject` — no YAML values files anywhere.

## GitOps repo structure

```
gitops/
├── clusters/                       Tanka envs that render ArgoCD Applications
│   ├── devops/
│   │   ├── main.jsonnet            app-of-apps for devops cluster
│   │   └── spec.json
│   └── prod/
│       ├── main.jsonnet
│       └── spec.json
├── environments/                   Tanka envs for first-party workloads
│   ├── devops/
│   │   ├── main.jsonnet
│   │   └── spec.json
│   └── prod/
│       ├── main.jsonnet
│       └── spec.json
├── lib/                            first-party libraries
│   ├── argocd-app.libsonnet
│   ├── alloy.libsonnet
│   ├── gitlab-runner.libsonnet
│   └── defaults.libsonnet
├── vendor/                         jsonnet-bundler managed
│   └── k8s-libsonnet/
├── jsonnetfile.json
└── jsonnetfile.lock.json
```

Repo lives in GitLab after bootstrap (`https://gitlab.lab.hezebonica.ca/homelab/gitops`).

## ArgoCD Application helper

`lib/argocd-app.libsonnet`:

```jsonnet
{
  new(config):: {
    apiVersion: 'argoproj.io/v1alpha1',
    kind: 'Application',
    metadata: { name: config.name, namespace: 'argocd' },
    spec: {
      project: 'default',
      source: config.source,
      destination: {
        server: 'https://kubernetes.default.svc',
        namespace: config.namespace,
      },
      syncPolicy: {
        automated: { prune: true, selfHeal: true },
        syncOptions: ['CreateNamespace=true'],
      },
    },
  },

  helm(name, namespace, repo, chart, version, values={}):: self.new({
    name: name,
    namespace: namespace,
    source: {
      repoURL: repo,
      chart: chart,
      targetRevision: version,
      helm: { valuesObject: values },
    },
  }),

  git(name, namespace, path, revision='HEAD'):: self.new({
    name: name,
    namespace: namespace,
    source: {
      repoURL: 'https://gitlab.lab.hezebonica.ca/homelab/gitops.git',
      path: path,
      targetRevision: revision,
    },
  }),
}
```

## App-of-apps example

`clusters/devops/main.jsonnet`:

```jsonnet
local app = import 'argocd-app.libsonnet';

{
  // Platform — third-party Helm
  cilium: app.helm('cilium', 'kube-system',
    'https://helm.cilium.io', 'cilium', '1.17.0',
    { kubeProxyReplacement: true }),

  metallb: app.helm('metallb', 'metallb-system',
    'https://metallb.github.io/metallb', 'metallb', '0.14.0', {}),

  longhorn: app.helm('longhorn', 'longhorn-system',
    'https://charts.longhorn.io', 'longhorn', '1.7.0',
    { defaultSettings: { defaultDataPath: '/var/mnt/longhorn' } }),

  external_secrets: app.helm('external-secrets', 'external-secrets',
    'https://charts.external-secrets.io', 'external-secrets', '0.10.0', {}),

  // Platform services — third-party Helm
  vault: app.helm('vault', 'vault',
    'https://helm.releases.hashicorp.com', 'vault', '0.29.0',
    { server: { ha: { enabled: true, replicas: 3 } } }),

  harbor: app.helm('harbor', 'registry',
    'https://helm.goharbor.io', 'harbor', '1.14.0',
    { expose: { type: 'clusterIP' }, externalURL: 'https://harbor.lab.hezebonica.ca' }),

  gitlab: app.helm('gitlab', 'gitlab',
    'https://charts.gitlab.io', 'gitlab', '8.7.0',
    {
      global: {
        hosts: { domain: 'lab.hezebonica.ca' },
        ingress: { configureCertmanager: false, tls: { enabled: false } },
      },
    }),

  argocd: app.helm('argocd', 'argocd',
    'https://argoproj.github.io/argo-helm', 'argo-cd', '7.7.0', {}),

  // First-party — git path to Tanka environment
  alloy:          app.git('alloy',          'observability',  'environments/devops'),
  gitlab_runner:  app.git('gitlab-runner',  'gitlab-runners', 'environments/devops'),
}
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
4. **`tk apply clusters/devops`** — creates all Application CRDs
5. **ArgoCD reconciles** — cert-manager → external-secrets → Vault (manual unseal) → Harbor → GitLab → runners → Alloy
6. **Configure Vault** — enable k8s auth, create policies, wire external-secrets
7. **Bootstrap GitLab** — root password, homelab group, gitops repo
8. **Add remaining Traefik routes** — one file-provider entry per service (vault, harbor, gitlab, etc.)
9. **Configure Renovate** — scheduled pipeline + `renovate.json` in the gitops repo; group-scoped GitLab token in Vault

Steps 1–3 are complete. Step 4 onward is next.

## Open questions / future work

- **Backup strategy** — Velero for k8s resources; Longhorn native backup target (S3 on a future NAS)
- **Harbor blob storage** — start on Longhorn; move to S3/NFS once a NAS exists
- **NAS** — not in scope yet; may appear as a Longhorn backup target + Harbor blob store
- **Autoscaling** — unnecessary at this size
- **Dedicated observability cluster** — blast-radius isolation, long-term consideration
- **Cluster upgrades** — `talosctl upgrade` per node; rehearse before production-critical use
- **Disaster recovery** — etcd snapshots via Talos; Velero for PV/k8s state
- **IP-allocation pre-flight** — an `arping`-based Terraform `data "external"` that fails a plan if the target IP is live on the LAN. Cheap belt-and-braces against static-IP collisions for Talos nodes, kube-vip VIP, and future scratch/service VMs. Firewalla API integration (for visibility into *leased-but-offline* devices + active IP reservation) is strictly heavier; only worth it if we also want reservation semantics. Deferred — revisit if the DHCP-pool shrink (above) ends up not sufficient.
