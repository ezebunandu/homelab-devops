variable "hosts" {
  description = "Hosts to install Tailscale on. The Traefik VM acts as subnet router; PVE hosts are plain nodes for direct SSH access."
  type = map(object({
    ip               = string
    ssh_user         = optional(string, "root")
    advertise_routes = optional(string, null) # CIDR to advertise; null = plain node
  }))
  default = {
    traefik = {
      ip               = "192.168.57.8"
      ssh_user         = "sam"
      advertise_routes = "192.168.57.0/24"
    }
    devops = {
      ip = "192.168.57.7"
    }
    devops2 = {
      ip = "192.168.57.9"
    }
    devops3 = {
      ip = "192.168.57.10"
    }
  }
}

variable "vault_secret_path" {
  description = "KV v2 path in Vault containing the Tailscale auth key (key: 'auth_key')."
  type        = string
  default     = "tailscale"
}
