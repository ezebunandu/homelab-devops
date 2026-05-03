# talos-cluster

Terraform module that provisions a 6-node Talos Linux cluster (3 control plane + 3 workers)
across a 3-node Proxmox cluster.

---

## Why Talos Linux

Talos Linux is a purpose-built, immutable operating system designed to do exactly one thing: run Kubernetes. Every architectural decision it makes flows from that constraint.

### The traditional approach: Ubuntu + kubeadm

With Ubuntu + kubeadm, you provision a general-purpose Linux server and install Kubernetes on top of it:

1. Provision VM, install Ubuntu
2. SSH in, configure networking, install container runtime, configure kernel modules and sysctls
3. Run `kubeadm init` on the control plane, `kubeadm join` on workers
4. Manage certificates, etcd, and the kubelet as separate systemd units
5. Keep OS packages updated separately from Kubernetes
6. Repeat for every node, hope they stay consistent

This works — kubeadm is battle-tested and well understood. The problems are operational and accumulate over time.

### What Talos does differently

Talos strips everything out that isn't required to run Kubernetes:

- No shell (`/bin/bash` does not exist)
- No SSH daemon
- No package manager (`apt`, `yum`, `apk` — none of them)
- No cron, no syslog, no standard init system
- The root filesystem is a read-only squashfs image

The node is managed exclusively through a gRPC API (`machined`) on port 50000. Every operation — applying config, upgrading the OS, rebooting, inspecting logs — goes through this API. `talosctl` is the CLI client for it.

### Advantage 1: Immutability eliminates configuration drift

On a traditional Linux node, the state of the system is the accumulated result of every command ever run on it. Over months, nodes that started identical diverge:

- Someone `apt install`-ed a debugging tool and forgot to remove it
- A sysctl was tweaked by hand to fix a networking issue
- A certificate was manually rotated into the wrong location
- A systemd unit was edited in-place

Talos nodes are stateless by design. The OS image is read-only. The only persistent state is the machine configuration YAML applied via the API and the data disk. If a node ever diverges from what the config says, the fix is to wipe and reapply — which takes under two minutes.

### Advantage 2: The API surface is the management surface

On Ubuntu, managing a node means managing SSH keys, sudoers, and shell access. Every person who has ever SSH'd into a node is a potential source of untracked change.

Talos has no SSH. The only way to interact with a node is the `machined` API, authenticated with mutual TLS using the cluster CA — the same CA that signs Kubernetes certificates. There is one credential store (Terraform state) and one management path.

For this cluster:
- The Terraform state file IS the source of truth for every node's configuration
- There are no out-of-band changes possible
- Rotating credentials means generating new machine secrets and reapplying — the same operation for every node

### Advantage 3: Declarative bootstrap from day zero

With kubeadm, bootstrapping a cluster is a series of imperative steps run in the right order on the right nodes — documented but not encoded. Losing a control plane node means running the bootstrap procedure again from memory.

Talos nodes boot into maintenance mode, accepting machine configuration over the API but running nothing else. When `terraform apply` runs:

1. Proxmox creates VMs from the Talos disk image
2. VMs boot into maintenance mode at their DHCP-reserved IPs
3. `talos_machine_configuration_apply` pushes the full node config — network, cluster membership, kubelet settings — over the API
4. `talos_machine_bootstrap` tells the first node to initialise etcd
5. The remaining nodes discover each other and join

The entire cluster goes from zero to running etcd and kubelet in one `terraform apply`. Rebuilding a lost node is the same operation: destroy the VM resource, run apply, the replacement joins automatically.

### Advantage 4: Kubernetes upgrades are first-class

On Ubuntu + kubeadm, upgrading Kubernetes means upgrading kubeadm via apt, running `kubeadm upgrade apply`, draining and upgrading each node, and keeping the Ubuntu kernel and Kubernetes versions compatible. The OS kernel and Kubernetes are managed by two different systems.

In Talos, the OS and Kubernetes are versioned together. An upgrade is:

```bash
talosctl upgrade --nodes 192.168.57.20 --image ghcr.io/siderolabs/talos:v1.13.0
talosctl upgrade-k8s --to 1.36.0
```

Talos drains the node, replaces the OS image atomically (A/B partition scheme), reboots, and rejoins the cluster. If anything fails it rolls back automatically.

### Advantage 5: Minimal attack surface

A default Ubuntu server runs dozens of services and has hundreds of packages installed. Hardening it for production is a project in itself.

Talos's attack surface is:
- The `machined` API on port 50000 (mTLS, cluster CA only)
- The kubelet API (standard Kubernetes)
- Whatever workloads you schedule

There is no sshd to patch, no bash to escape to, and no unnecessary kernel modules loaded.

---

## Cluster design

### Infrastructure overview

**Proxmox hosts:**

| Host    | IP             | Hardware                          | vCPU | RAM     |
|---------|----------------|-----------------------------------|------|---------|
| devops  | 192.168.57.7   | Dell T3600 — primary API endpoint | 8    | 64 GB   |
| devops2 | 192.168.57.9   |                                   | 4    | 15.5 GB |
| devops3 | 192.168.57.10  | Intel i5-7500T                    | 4    | 15.5 GB |

**Talos nodes (one CP + one Worker per Proxmox host):**

| Node     | Type | Proxmox host | IP             | vCPU | RAM  | OS disk          | Data disk        | MAC               |
|----------|------|--------------|----------------|------|------|------------------|------------------|-------------------|
| talos-01 | CP   | devops       | 192.168.57.20  | 4    | 8 GB | 32 GB local-ssd  | 100 GB local-lvm | BC:24:11:6E:9D:82 |
| talos-02 | CP   | devops2      | 192.168.57.21  | 2    | 8 GB | 32 GB local-lvm  | 100 GB local-lvm | BC:24:11:50:0D:8F |
| talos-03 | CP   | devops3      | 192.168.57.22  | 2    | 8 GB | 32 GB local-lvm  | 100 GB local-lvm | BC:24:11:4B:C8:25 |
| talos-04 | Worker | devops     | 192.168.57.23  | 2    | 8 GB | 32 GB local-ssd  | 200 GB local-lvm | BC:24:11:11:B2:75 |
| talos-05 | Worker | devops2    | 192.168.57.24  | 2    | 7 GB | 32 GB local-lvm  | 200 GB local-lvm | BC:24:11:71:A9:6A |
| talos-06 | Worker | devops3    | 192.168.57.25  | 2    | 7 GB | 32 GB local-lvm  | 200 GB local-lvm | BC:24:11:4A:EC:01 |

**Proxmox storage pools:**

| Host    | OS pool   | Data pool |
|---------|-----------|-----------|
| devops  | local-ssd | local-lvm |
| devops2 | local-lvm | local-lvm |
| devops3 | local-lvm | local-lvm |

### Topology decisions

`allowSchedulingOnControlPlanes: false` — all workloads are scheduled exclusively on the three
worker nodes. The control plane nodes run etcd and the Kubernetes control plane components only.
etcd quorum requires 2 of 3 CP nodes.

### Talos native L2 VIP

Talos has built-in L2 VIP support in `networkd` — a floating IP that moves between nodes using
gratuitous ARP based on etcd lease ownership. This achieves the same result as kube-vip without
running an additional pod in the control plane.

The VIP is 192.168.57.30. It is currently blocked by Firewalla's ARP spoofing protection — see
Known Issues.

### Cilium with kube-proxy replacement

kube-proxy is disabled (`cluster.proxy.disabled: true`) and Cilium is installed with
`kubeProxyReplacement=true`. Cilium implements service routing using eBPF programs in the kernel
rather than iptables rules, which is more efficient and provides better observability via Hubble.

The trade-off: Cilium must be installed before any ClusterIP service routing works.

### MetalLB L2 load balancer

MetalLB announces LoadBalancer service IPs over L2 (gratuitous ARP) from the L2 pool
192.168.57.100–192.168.57.120. These IPs are excluded from the Firewalla DHCP pool.

MetalLB speaker pods require privileged access. The `metallb-system` namespace is labelled
`pod-security.kubernetes.io/enforce=privileged` by `post-apply.sh` before the Helm install.

MetalLB L2 advertisements are also subject to the same Firewalla ARP spoofing issue as the VIP —
see Known Issues.

### Longhorn distributed storage

Longhorn provides distributed block storage with replication across the worker nodes. Worker nodes
have 200 GB data disks dedicated to replica storage. Control plane nodes carry a 100 GB data disk
used only for the Longhorn CSI manager — they do not host replicas.

Longhorn requires two Talos extensions baked into the OS image (`iscsi-tools`, `util-linux-tools`)
and a dedicated data disk on each node mounted at `/var/lib/longhorn`. Both are provisioned
automatically — extensions via the Image Factory schematic, disk mount via the machine config patch.

The `longhorn-system` namespace must be labelled `pod-security.kubernetes.io/enforce=privileged`
before install. Longhorn's manager runs as a privileged container with `hostPath` volume mounts —
Kubernetes's default `baseline` PodSecurity enforcement blocks it. `post-apply.sh` handles this
before the Helm install.

### Disk layout

Control plane nodes and worker nodes have different data disk sizes:

| Role    | Disk   | Size   | Purpose                                            |
|---------|--------|--------|----------------------------------------------------|
| All     | scsi0  | 32 GB  | Talos OS + etcd (SSD on devops for fsync latency)  |
| CP      | scsi1  | 100 GB | Longhorn CSI manager only — no replica data        |
| Worker  | scsi1  | 200 GB | Longhorn replica storage (bulk data capacity)      |

The system disk can be wiped and reprovisioned without touching the data disk. SSD is used for
the OS disk on devops because etcd is extremely sensitive to fsync latency.

### etcd peer URL pinning

By default, Talos selects a node's primary IP for etcd peer communication by picking the first
non-loopback interface. When Cilium is the CNI, it creates virtual overlay interfaces
(`10.0.x.x`) that may be elected over the physical interface — and those overlay addresses only
exist after Cilium starts, which requires etcd to already be running.

This chicken-and-egg dependency causes etcd to fail its health check on every node reboot: the
node comes up, etcd starts, tries to reach peers via their Cilium overlay addresses, finds none
of them present, and never achieves quorum. The cluster is unrecoverable without a full reset.

Fixed by adding `cluster.etcd.advertisedSubnets: [192.168.57.0/24]` to the machine config,
which forces etcd to advertise on the physical subnet regardless of what other interfaces are
present.

---

## Pre-flight

### 1. Register MAC→IP reservations in Firewalla

The VMs have pinned MAC addresses so they always receive the same IPs on recreate. Add all six
reservations in the Firewalla app before running `terraform apply` (see the node table above).

### 2. Download the Talos image onto each Proxmox host

The Proxmox provider's download resource has a known connectivity issue with the
`query-url-metadata` API call, so the image is pre-downloaded manually. The script uses the
Talos Image Factory (instead of GitHub releases) because it serves `.raw.zst` — the only
compression format the provider accepts. It bakes three extensions into the image via a
schematic:

| Extension | Purpose |
|-----------|---------|
| `siderolabs/qemu-guest-agent` | Proxmox IP reporting and graceful shutdown |
| `siderolabs/iscsi-tools` | iscsid daemon required by Longhorn |
| `siderolabs/util-linux-tools` | `nsenter` required by Longhorn system pods |

Run the script once per Proxmox host, passing the hostname as an argument. The script SSHes to
the target host and executes itself there:

```bash
./download-talos-image.sh devops
./download-talos-image.sh devops2
./download-talos-image.sh devops3
```

The script is idempotent — it skips the download if the image already exists on that host. To
bump the Talos version, update `VERSION` in `download-talos-image.sh` and re-run. The schematic
ID stays the same as long as the extension list doesn't change.

### 3. Load SSH key into agent

The bpg/proxmox provider uses SSH for disk operations:

```bash
eval $(ssh-agent) && ssh-add ~/.ssh/id_ed25519
```

---

## Apply

```bash
terraform init
terraform apply
bash post-apply.sh
```

`post-apply.sh` runs in order:

1. Writes kubeconfig, patches server URL to `192.168.57.20:6443` (bypasses the blocked VIP)
2. Installs Cilium (kube-proxy replacement, Talos-specific capability flags)
3. Installs MetalLB, labels namespace privileged, applies IP pool CRs (`192.168.57.100–120`)
4. Installs Longhorn, labels namespace privileged
5. Installs ArgoCD with MetalLB IP `192.168.57.100` and insecure mode enabled, prints the initial admin password

**ArgoCD Traefik route** — after `post-apply.sh` completes, copy the dynamic config to the Traefik VM to expose the UI at `https://argocd.lab.hezebonica.ca`:

```bash
scp terraform/traefik-vm/dynamic.d/30-k8s-argocd.yml \
  sam@192.168.57.8:~/traefik/dynamic.d/30-k8s-argocd.yml
```

Traefik hot-reloads the file provider — no restart needed.

> **ArgoCD Helm gotcha:** insecure mode must be set via `configs.params.server\.insecure=true`
> (writes to `argocd-cmd-params-cm`), **not** `server.insecure=true` which is silently ignored
> in chart v7+.

## Upgrading nodes (Talos version or extensions change)

When `talos.tf` schematic extensions or `talos_version` changes, run the upgrade script
before `terraform apply`. It resolves the new schematic ID, downloads the updated image
onto PVE, upgrades each node one at a time via `talosctl` (A/B atomic upgrade — no data
loss), and verifies cluster health.

```bash
bash upgrade-nodes.sh
terraform apply
```

---

## Known issues

**VIP (192.168.57.30) unreachable from client machines.** Firewalla's ARP spoofing protection
blocks the gratuitous ARP the VIP-holding node broadcasts. `kubectl` is pointed at
`192.168.57.20:6443` directly as a workaround. The cluster itself is unaffected — internal
traffic routes correctly. Fix: disable ARP spoofing protection in Firewalla for the
192.168.57.x segment.

**MetalLB L2 advertisements blocked by Firewalla ARP spoofing.** Same root cause as the VIP
issue — Firewalla drops gratuitous ARP from MetalLB speaker pods, so LoadBalancer IPs in the
192.168.57.100–120 pool are unreachable from LAN clients. Fix: same as the VIP fix above.

**Node names are auto-generated** (e.g. `talos-2zx-qpc` instead of `talos-01`). Proxmox
injects the VM name as an SMBIOS hostname on boot and Talos reads it, causing a conflict
when a `machine.network.hostname` patch is also applied. The VM names in Proxmox are correct;
the Kubernetes node names are non-deterministic.
