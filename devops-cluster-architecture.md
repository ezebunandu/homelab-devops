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

## Decisions locked in (2026-04-20)

| Decision | Choice | Rationale |
|---|---|---|
| Cluster topology | 3 compact nodes (control + worker combined) | Single physical host = single SPOF; CP/worker split buys nothing |
| Node OS | Talos Linux | Immutable, API-driven, minimal attack surface |
| CNI | Cilium | NetworkPolicy + L7 observability + eBPF |
| Kube API VIP | kube-vip (L2 mode) | Simpler than Cilium L2 announcements |
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
Proxmox: devops (192.168.57.7)
├── traefik        192.168.57.8         edge proxy (existing VM)
├── talos-01       192.168.57.20        control + worker
├── talos-02       192.168.57.21        control + worker
├── talos-03       192.168.57.22        control + worker
└── kube API VIP   192.168.57.30        floating (kube-vip, L2)
```

`kubectl` targets `https://192.168.57.30:6443` — doesn't care which CP node is up.

## Node specs

Per Talos VM:

| Resource | Value |
|---|---|
| vCPU | 4 (host passthrough) |
| RAM | 16 GB |
| Root disk | 32 GB (scsi0) — Talos system |
| Data disk | 200 GB (scsi1) — Longhorn replica |
| Network | single NIC on `vmbr0`, static IP |
| Firmware | SeaBIOS |
| Machine type | q35 |
| SCSI controller | virtio-scsi-single |

Totals: 12 vCPU, 48 GB RAM, ~700 GB storage committed to k8s. Leaves ~300 GB on the T3600 for Proxmox, Traefik VM, ISOs, snapshots.

## Network layout

| Range | Purpose |
|---|---|
| `192.168.57.0/24` | Existing LAN; all VMs here |
| `192.168.57.30` | kube API VIP (kube-vip managed) |
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

## Stack + namespace layout

```
kube-system        cilium, coredns, kube-vip, metrics-server
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
| **Cluster budget (48 GB)** | ~17 GB headroom |

## Edge integration — Traefik VM stays

LAN DNS wildcard `*.lab.hezebonica.ca` already points at `192.168.57.8`. Traefik's file provider routes each cluster service to its MetalLB IP:

```yaml
# ~/traefik/dynamic.yml on the edge VM
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

1. **Provision 3 Talos VMs on Proxmox** — new Terraform module `terraform/talos-cluster/`, parallel to `terraform/traefik-vm/`
2. **Generate Talos machine configs** — `talosctl gen config` with kube-vip static pod baked in
3. **Apply machine configs** — `talosctl apply-config` to each node
4. **Bootstrap etcd** — `talosctl bootstrap` on first control-plane node
5. **Pull kubeconfig** — `talosctl kubeconfig`; verify `kubectl get nodes`
6. **Install Cilium** — CLI or initial Helm install (networking before anything else)
7. **Install ArgoCD** — one-time Helm install
8. **`tk apply clusters/devops`** — creates all Application CRDs
9. **ArgoCD reconciles** — MetalLB → Longhorn → cert-manager → external-secrets → Vault (manual unseal) → Harbor → GitLab → runners → Alloy
10. **Configure Vault** — enable k8s auth, create policies, wire external-secrets
11. **Bootstrap GitLab** — root password, homelab group, gitops repo
12. **Add edge Traefik routes** — one file-provider entry per service
13. **Configure Renovate** — scheduled pipeline + `renovate.json` in the gitops repo; group-scoped GitLab token in Vault; see "Dependency automation — Renovate"

Steps 1–8 are one-shot. Step 9 is hands-off (watch ArgoCD sync). Steps 10–13 are platform config.

## Open questions / future work

- **Backup strategy** — Velero for k8s resources; Longhorn native backup target (S3 on a future NAS)
- **Harbor blob storage** — start on Longhorn; move to S3/NFS once a NAS exists
- **NAS** — not in scope yet; may appear as a Longhorn backup target + Harbor blob store
- **Autoscaling** — unnecessary at this size
- **Dedicated observability cluster** — blast-radius isolation, long-term consideration
- **Cluster upgrades** — `talosctl upgrade` per node; rehearse before production-critical use
- **Disaster recovery** — etcd snapshots via Talos; Velero for PV/k8s state
