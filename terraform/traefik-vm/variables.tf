variable "pve_endpoint" {
  type        = string
  description = "PVE API endpoint, e.g. https://192.168.57.7:8006/"
}

variable "pve_api_token" {
  type        = string
  description = "Full token: terraform@pve!main=xxxxxxxx-..."
  sensitive   = true
}

variable "pve_insecure_tls" {
  type        = bool
  default     = true
  description = "Accept PVE self-signed cert. Flip to false once PVE UI is fronted by a valid cert."
}

variable "pve_node" {
  type        = string
  default     = "devops"
  description = "PVE node name (output of `hostname` on the node)."
}

variable "vm_name" {
  type    = string
  default = "traefik"
}

variable "vm_cpu_cores" {
  type    = number
  default = 2
}

variable "vm_memory_mb" {
  type    = number
  default = 2048
}

variable "vm_disk_gb" {
  type    = number
  default = 20
}

variable "vm_disk_datastore" {
  type        = string
  default     = "local-lvm"
  description = "Storage for VM disks. Change if you use ZFS/Ceph."
}

variable "vm_bridge" {
  type    = string
  default = "vmbr0"
}

variable "vm_ip_cidr" {
  type        = string
  description = "Static IPv4 in CIDR notation, e.g. 192.168.57.10/24"
}

variable "vm_gateway" {
  type        = string
  description = "IPv4 gateway, e.g. 192.168.57.1"
}

variable "admin_user" {
  type    = string
  default = "sam"
}

variable "ssh_public_key" {
  type        = string
  description = "Contents of ~/.ssh/id_ed25519.pub (or similar)"
}
