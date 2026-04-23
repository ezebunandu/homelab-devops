# Download the Talos disk image from the Image Factory (metal-amd64.raw.zst).
# The schematic ID encodes the qemu-guest-agent extension — same ID every time
# the same schematic is submitted, so this download is fully reproducible.
resource "proxmox_virtual_environment_vm" "talos" {
  for_each = var.nodes

  name      = each.key
  node_name = var.pve_node
  tags      = ["homelab", "talos", "terraform", "k8s"]

  machine       = "q35"
  scsi_hardware = "virtio-scsi-pci"
  bios          = "seabios"

  agent {
    enabled = true
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 16384
  }

  # scsi0 — Talos system disk on the SSD thin pool (fast etcd fsyncs).
  # Cloned from the factory image; boots directly into Talos maintenance mode.
  disk {
    datastore_id = "local-ssd"
    file_id      = "local:iso/talos-${talos_image_factory_schematic.this.id}-${var.talos_version}.img"
    interface    = "scsi0"
    size         = 32
    discard      = "on"
    ssd          = true
  }

  # scsi1 — Longhorn replica disk on the spindle thin pool (bulk capacity)
  disk {
    datastore_id = "local-lvm"
    file_format  = "raw"
    interface    = "scsi1"
    size         = 200
    discard      = "on"
  }

  boot_order = ["scsi0"]

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }
}
