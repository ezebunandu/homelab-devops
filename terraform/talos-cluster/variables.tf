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

variable "pve_node" {
  type    = string
  default = "devops"
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

variable "nodes" {
  type = map(object({
    ip = string
  }))
  default = {
    talos-01 = { ip = "192.168.57.20" }
    talos-02 = { ip = "192.168.57.21" }
    talos-03 = { ip = "192.168.57.22" }
  }
  description = "Map of node names to their static IP addresses."
}
