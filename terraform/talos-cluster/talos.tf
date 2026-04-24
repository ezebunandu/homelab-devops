# Schematic posted to factory.talos.dev — includes qemu-guest-agent so Proxmox
# can report VM IPs and coordinate graceful shutdown/snapshot.
# The returned ID is a deterministic content hash; same inputs → same ID.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = ["siderolabs/qemu-guest-agent"]
      }
    }
  })
}

# Resolves download URLs for the schematic + version combination.
# urls.disk_image → metal-amd64.raw.zst (raw disk, zstd-compressed)
data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "metal"
  architecture  = "amd64"
}

# Cluster secrets — CA, bootstrap token, encryption keys.
# Generated once and stored in Terraform state. Back up the state file.
resource "talos_machine_secrets" "cluster" {}

# Renders the talosconfig YAML from the cluster secrets.
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoints            = [for name, node in var.nodes : node.ip]
  nodes                = [for name, node in var.nodes : node.ip]
}

# Base control plane machine configuration (rendered once, patched per-node).
data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
}

# Apply config to each node with per-node patches merged on top.
resource "talos_machine_configuration_apply" "node" {
  for_each = var.nodes

  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = each.value.ip

  config_patches = [
    # Compact cluster: allow workloads on control plane nodes
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
        # Cilium replaces kube-proxy — must be disabled before Cilium is installed
        network = { cni = { name = "none" } }
        proxy   = { disabled = true }
      }
    }),
    # Per-node hostname — must be a separate patch from the interfaces block
    # to avoid "static hostname already set" validation errors on re-apply.
    yamlencode({
      machine = { network = { hostname = each.key } }
    }),
    # Per-node network: static IP + default route + Talos native L2 VIP.
    # The VIP (192.168.57.30) floats to whichever control-plane node holds
    # the etcd lease — no kube-vip pod required.
    yamlencode({
      machine = {
        network = {
          interfaces = [{
            interface = "eth0"
            addresses = ["${each.value.ip}/24"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = var.gateway
            }]
            vip = { ip = var.cluster_vip }
          }]
          nameservers = ["1.1.1.1", "8.8.8.8"]
        }
      }
    }),
  ]

  depends_on = [proxmox_virtual_environment_vm.talos]
}

# Bootstrap etcd on the first control plane node.
# Only runs once — etcd joins the cluster on its own after this point.
resource "talos_machine_bootstrap" "cluster" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = values(var.nodes)[0].ip

  depends_on = [talos_machine_configuration_apply.node]
}

# Retrieve kubeconfig once the cluster is up.
resource "talos_cluster_kubeconfig" "cluster" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = values(var.nodes)[0].ip

  depends_on = [talos_machine_bootstrap.cluster]
}
