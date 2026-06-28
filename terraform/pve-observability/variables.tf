variable "alloy_version" {
  description = "Grafana Alloy release version to install (without leading 'v'). Check https://github.com/grafana/alloy/releases for the latest."
  type        = string
  default     = "1.17.0"
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
  description = "KV v2 secret path in Vault containing Grafana Cloud endpoints and the management_token."
  type        = string
  default     = "grafana-cloud"
}

variable "grafana_cloud_region" {
  description = "Grafana Cloud region slug for the stack (e.g. prod-us-east-0, prod-eu-west-2). Find it in the stack's connection details / URL."
  type        = string
}

variable "grafana_cloud_stack_id" {
  description = "Numeric Grafana Cloud stack ID — the realm identifier the ingest access policy is scoped to. Find it at grafana.com under your org's stacks."
  type        = string
}
