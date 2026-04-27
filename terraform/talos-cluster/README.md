# talos-cluster

Terraform module that provisions a 3-node Talos Linux cluster on the devops Proxmox node.

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

### Compact control-plane-only topology

All three nodes are control plane nodes with `allowSchedulingOnControlPlanes: true`. There are no dedicated worker nodes. This is appropriate for a homelab where:
- Resource efficiency matters — three nodes is the etcd quorum minimum
- Workloads are not sensitive to control plane co-location
- Simpler to manage — one node type, one config

### Talos native L2 VIP

Talos has built-in L2 VIP support in `networkd` — a floating IP that moves between nodes using gratuitous ARP based on etcd lease ownership. This achieves the same result as kube-vip without running an additional pod in the control plane.

The VIP (192.168.57.30) is currently blocked by Firewalla's ARP spoofing protection. See Known Issues.

### Cilium with kube-proxy replacement

kube-proxy is disabled (`cluster.proxy.disabled: true`) and Cilium is installed with `kubeProxyReplacement=true`. Cilium implements service routing using eBPF programs in the kernel rather than iptables rules, which is more efficient and provides better observability via Hubble.

The trade-off: Cilium must be installed before any ClusterIP service routing works.

### Disk layout

Each node has two disks:

| Disk   | Datastore   | Size   | Purpose                        |
|--------|-------------|--------|-------------------------------|
| scsi0  | local-ssd   | 32 GB  | Talos OS + etcd (SSD for fsync latency) |
| scsi1  | local-lvm   | 200 GB | Longhorn replica data (spindle, bulk capacity) |

The system disk can be wiped and reprovisioned without touching replica data. SSD is used for etcd because etcd is extremely sensitive to fsync latency.

---

## Pre-flight

### 1. Set up SSH keys on the PVE node

The bpg/proxmox provider uses SSH for disk operations. Run once from the machine you'll apply from:

```bash
ssh-copy-id root@192.168.57.7
eval $(ssh-agent) && ssh-add ~/.ssh/id_ed25519
```

### 2. Set DHCP reservations on Firewalla

The VMs have pinned MAC addresses so they always get the same IPs on recreate.
Add these reservations in the Firewalla app before running `terraform apply`:

| Node     | MAC               | IP            |
|----------|-------------------|---------------|
| talos-01 | BC:24:11:6E:9D:82 | 192.168.57.20 |
| talos-02 | BC:24:11:9F:9F:BC | 192.168.57.21 |
| talos-03 | BC:24:11:D4:8C:AE | 192.168.57.22 |

### 3. Download the Talos image onto the PVE node

The Proxmox provider's download resource has a known connectivity issue with the
`query-url-metadata` API call, so the image is pre-downloaded manually. The script uses the
Talos Image Factory (instead of GitHub releases) because it serves `.raw.zst` — the only
compression format the provider accepts. It also bakes in the `qemu-guest-agent` extension
via a schematic so Proxmox can report VM IPs and coordinate graceful shutdown.

```bash
# Run from your local machine — streams and executes on PVE directly
ssh root@192.168.57.7 bash < download-talos-image.sh
```

The script is idempotent — it skips the download if the image already exists. To bump the
Talos version, update `VERSION` in `download-talos-image.sh` and re-run. The schematic ID
stays the same as long as the extension list doesn't change.

---

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
cp .envrc.example .envrc   # fill in pve_api_token, then: direnv allow .
terraform init
terraform apply
```

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

## Post-apply

Writes kubeconfig, patches the server URL to bypass the blocked VIP, and installs Cilium
with the Talos-specific capability and cgroup flags required.

```bash
bash post-apply.sh
```

---

## Known issues

**Node names are auto-generated** (e.g. `talos-sm9-jbn` instead of `talos-01`). Proxmox
injects the VM name as an SMBIOS hostname on boot and Talos reads it, causing a conflict
when a `machine.network.hostname` patch is also applied. The VM names in Proxmox are correct;
the Kubernetes node names are just non-deterministic.

**VIP (192.168.57.30) unreachable from client machines.** Firewalla's ARP spoofing protection
blocks the gratuitous ARP the VIP-holding node broadcasts. `kubectl` is pointed at
`192.168.57.20:6443` directly. The cluster itself is unaffected — internal traffic routes
correctly.

**Node INTERNAL-IP shows Cilium overlay addresses (10.x.x.x).** Fixed by adding
`kubelet.nodeIP.validSubnets: [192.168.57.0/24]` to the machine config patch, which tells
the kubelet to ignore Cilium's virtual interfaces when selecting its node IP.
