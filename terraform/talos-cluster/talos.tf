# Schematic posted to factory.talos.dev — bakes extensions into the OS image.
# Extensions: qemu-guest-agent (Proxmox), iscsi-tools (Longhorn), util-linux-tools (Longhorn nsenter).
# The returned ID is a deterministic content hash; same inputs → same ID.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/qemu-guest-agent",
          "siderolabs/iscsi-tools",
          "siderolabs/util-linux-tools",
        ]
      }
    }
  })
}

# Resolves download URLs for the schematic + version combination.
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
  endpoints            = [for name, node in var.nodes : node.ip if node.machine_type == "controlplane"]
  nodes                = [for name, node in var.nodes : node.ip]
}

# Base control plane machine configuration.
data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
}

# Base worker machine configuration.
data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
}

# Apply config to each node with per-node patches merged on top.
resource "talos_machine_configuration_apply" "node" {
  for_each = var.nodes

  client_configuration = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = (
    each.value.machine_type == "controlplane"
    ? data.talos_machine_configuration.controlplane.machine_configuration
    : data.talos_machine_configuration.worker.machine_configuration
  )
  node = each.value.ip

  config_patches = concat(
    # Cluster-level patch: control planes only
    each.value.machine_type == "controlplane" ? [yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = false
        network = { cni = { name = "none" } }
        proxy   = { disabled = true }
        # Pin etcd peer URLs to the physical subnet so they survive reboots.
        etcd = { advertisedSubnets = ["192.168.57.0/24"] }
      }
    })] : [],

    # Per-node patch: all nodes
    [yamlencode({
      machine = {
        kubelet = {
          nodeIP = { validSubnets = ["192.168.57.0/24"] }
        }
        disks = [{
          device     = "/dev/sdb"
          partitions = [{ mountpoint = "/var/lib/longhorn" }]
        }]
        network = {
          interfaces = [merge(
            {
              interface = "eth0"
              addresses = ["${each.value.ip}/24"]
              routes    = [{ network = "0.0.0.0/0", gateway = var.gateway }]
            },
            # VIP floats across control plane nodes only
            each.value.machine_type == "controlplane" ? { vip = { ip = var.cluster_vip } } : {}
          )]
          nameservers = ["1.1.1.1", "8.8.8.8"]
        }
      }
    })]
  )

  depends_on = [proxmox_virtual_environment_vm.talos]
}

# Bootstrap etcd on the first control plane node.
# Only runs once — other CPs join automatically.
resource "talos_machine_bootstrap" "cluster" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = [for name, node in var.nodes : node.ip if node.machine_type == "controlplane"][0]

  depends_on = [talos_machine_configuration_apply.node]
}

# Retrieve kubeconfig once the cluster is up.
resource "talos_cluster_kubeconfig" "cluster" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = [for name, node in var.nodes : node.ip if node.machine_type == "controlplane"][0]

  depends_on = [talos_machine_bootstrap.cluster]
}
