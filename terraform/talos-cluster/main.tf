resource "proxmox_virtual_environment_vm" "talos" {
  for_each = var.nodes

  name      = each.key
  node_name = each.value.host
  tags      = ["homelab", "talos", "terraform", "k8s"]

  machine       = "q35"
  scsi_hardware = "virtio-scsi-pci"
  bios          = "seabios"

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.vcpu
    type  = "host"
  }

  memory {
    dedicated = each.value.mem
  }

  # scsi0 — Talos system disk. Uses the SSD pool on devops, lvm pool on devops2/devops3.
  disk {
    datastore_id = var.hosts[each.value.host].os_pool
    file_id      = "local:iso/talos-${talos_image_factory_schematic.this.id}-${var.talos_version}.img"
    interface    = "scsi0"
    size         = 32
    discard      = "on"
    ssd          = true
  }

  # scsi1 — Longhorn replica disk. Workers get 200 GB, control planes get 100 GB (CSI only).
  disk {
    datastore_id = var.hosts[each.value.host].data_pool
    file_format  = "raw"
    interface    = "scsi1"
    size         = each.value.machine_type == "controlplane" ? 100 : 200
    discard      = "on"
  }

  boot_order = ["scsi0"]

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = each.value.mac
  }

  operating_system {
    type = "l26"
  }

  # The file_id (boot image) is ignored after initial creation — node OS upgrades
  # are done via `talosctl upgrade`, not by replacing the VM disk through terraform.
  lifecycle {
    ignore_changes = [disk[0].file_id]
  }
}
