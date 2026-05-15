# 1. Pull the Debian 12 generic cloud image onto the node
resource "proxmox_virtual_environment_download_file" "debian_12" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.pve_node
  url          = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
  file_name    = "debian-12-generic-amd64.img"
}

# 2. Render cloud-init user-data from template and upload as a snippet
resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.pve_node

  source_raw {
    file_name = "${var.vm_name}-user-data.yaml"
    data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      hostname       = var.vm_name
      admin_user     = var.admin_user
      ssh_public_key = var.ssh_public_key
    })
  }
}

# 3. The VM itself
resource "proxmox_virtual_environment_vm" "traefik" {
  name          = var.vm_name
  node_name     = var.pve_node
  tags          = ["homelab", "traefik", "terraform"]
  scsi_hardware = "virtio-scsi-single"

  agent {
    enabled = true
  }

  cpu {
    cores = var.vm_cpu_cores
    # x86-64-v2-AES: stable virtual CPU model, vendor-agnostic, retains AES-NI
    # for TLS. Avoid 'host' — passing raw Ryzen CPUID through to the Debian 12
    # stable kernel triggers an SRSO-related panic during init on the MS-A2.
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  disk {
    datastore_id = var.vm_disk_datastore
    file_id      = proxmox_virtual_environment_download_file.debian_12.id
    interface    = "scsi0"
    size         = var.vm_disk_gb
    discard      = "on"
  }

  network_device {
    bridge = var.vm_bridge
  }

  initialization {
    datastore_id = var.vm_disk_datastore
    interface    = "scsi1"

    ip_config {
      ipv4 {
        address = var.vm_ip_cidr
        gateway = var.vm_gateway
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init.id
  }

  operating_system {
    type = "l26"
  }
}

output "vm_ipv4" {
  value = split("/", var.vm_ip_cidr)[0]
}

output "ssh_command" {
  value = "ssh ${var.admin_user}@${split("/", var.vm_ip_cidr)[0]}"
}
