variable "pve_endpoint" {
  type        = string
  default     = "https://192.168.57.7:8006/"
  description = "PVE API endpoint."
}

variable "pve_api_token" {
  type        = string
  description = "Full Proxmox API token. Pass via TF_VAR_pve_api_token rather than a tfvars file."
  sensitive   = true
}

variable "pve_insecure_tls" {
  type    = bool
  default = true
}

variable "cluster_name" {
  type        = string
  default     = "devops"
  description = "Talos / Kubernetes cluster name. Used in kubeconfig context name."
}

variable "cluster_vip" {
  type        = string
  default     = "192.168.57.30"
  description = "Floating VIP for the Kubernetes API server (Talos native L2 VIP)."
}

variable "cluster_endpoint" {
  type        = string
  default     = "https://192.168.57.30:6443"
  description = "Kubernetes API server endpoint. Points at the VIP."
}

variable "gateway" {
  type    = string
  default = "192.168.57.1"
}

variable "talos_version" {
  type        = string
  default     = "v1.12.6"
  description = "Talos release tag. Determines the nocloud image URL and machine config schema."
}

variable "kubernetes_version" {
  type        = string
  default     = "v1.35.2"
  description = "Kubernetes version to install. Must be supported by the chosen Talos version."
}

variable "hosts" {
  type = map(object({
    os_pool   = string
    data_pool = string
  }))
  default = {
    devops  = { os_pool = "local-ssd", data_pool = "local-lvm" }
    devops2 = { os_pool = "local-lvm", data_pool = "local-lvm" }
    devops3 = { os_pool = "local-lvm", data_pool = "local-lvm" }
  }
  description = "Per-host storage pool names. os_pool for root disk, data_pool for Longhorn disk."
}

variable "nodes" {
  type = map(object({
    ip           = string
    mac          = optional(string, null)
    host         = string
    machine_type = string
    vcpu         = number
    mem          = number
  }))
  default = {
    talos-01 = { ip = "192.168.57.20", mac = "BC:24:11:6E:9D:82", host = "devops",  machine_type = "controlplane", vcpu = 4, mem = 8192 }
    talos-02 = { ip = "192.168.57.21", mac = null,                 host = "devops2", machine_type = "controlplane", vcpu = 2, mem = 8192 }
    talos-03 = { ip = "192.168.57.22", mac = null,                 host = "devops3", machine_type = "controlplane", vcpu = 2, mem = 8192 }
    talos-04 = { ip = "192.168.57.23", mac = null,                 host = "devops",  machine_type = "worker",       vcpu = 2, mem = 8192 }
    talos-05 = { ip = "192.168.57.24", mac = null,                 host = "devops2", machine_type = "worker",       vcpu = 2, mem = 7168 }
    talos-06 = { ip = "192.168.57.25", mac = null,                 host = "devops3", machine_type = "worker",       vcpu = 2, mem = 7168 }
  }
  description = "All cluster nodes. Fill in real MACs after first apply for Firewalla consistency."
}
