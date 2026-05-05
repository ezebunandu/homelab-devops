variable "alloy_version" {
  description = "Grafana Alloy release version to install (without leading 'v'). Check https://github.com/grafana/alloy/releases for the latest."
  type        = string
  default     = "1.8.1"
}

variable "pve_hosts" {
  description = "Map of Proxmox hostname to management IP. Alloy is installed on each."
  type        = map(string)
  default = {
    devops  = "192.168.57.7"
    devops2 = "192.168.57.9"
    devops3 = "192.168.57.10"
  }
}

variable "vault_secret_path" {
  description = "KV v2 secret path in Vault containing Grafana Cloud credentials."
  type        = string
  default     = "grafana-cloud"
}
