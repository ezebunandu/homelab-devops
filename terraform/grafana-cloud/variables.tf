variable "grafana_cloud_region" {
  description = "Grafana Cloud region slug for the stack (e.g. prod-us-east-0, prod-eu-west-2)."
  type        = string
}

variable "grafana_cloud_stack_id" {
  description = "Numeric Grafana Cloud stack ID — the realm identifier ingest access policies are scoped to."
  type        = string
}

variable "vault_secret_path" {
  description = "KV v2 secret path (under mount 'secret') holding the Grafana Cloud endpoints, instance-ID usernames, and the accesspolicies:write management_token."
  type        = string
  default     = "grafana-cloud"
}
