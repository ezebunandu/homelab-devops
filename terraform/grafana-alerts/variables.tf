variable "vault_secret_path" {
  description = "KV v2 secret path (mount 'secret') holding the Grafana Cloud stack URL and a stack service-account token. Expected keys: stack_url, stack_sa_token."
  type        = string
  default     = "grafana-cloud"
}

variable "prometheus_datasource_uid" {
  description = "UID of the stack's Grafana Cloud Prometheus (Mimir) datasource — the alert rules query it. Find it under Connections → Data sources in the stack (e.g. 'grafanacloud-<org>-prom')."
  type        = string
}

variable "loki_datasource_uid" {
  description = "UID of the stack's Grafana Cloud Loki datasource — the Security Detections rule group queries it (Falco native alert; Sigma-provisioned rules query it too, via homelab-detections' config.yml). Find it under Connections → Data sources (e.g. 'grafanacloud-<org>-logs')."
  type        = string
}

variable "discord_webhook_url" {
  description = "Discord webhook URL that real alerts (node/pod/PV/target) are posted to."
  type        = string
  sensitive   = true
}

variable "deadmansswitch_webhook_url" {
  description = "Heartbeat receiver URL for the dead-man's-switch — NOT a Discord webhook. The DMS fires continuously; this endpoint must ALARM WHEN THE PINGS STOP (e.g. a healthchecks.io check URL, Grafana OnCall heartbeat, Better Uptime). Discord can't detect absence, so it can't serve as the DMS receiver directly — instead configure that heartbeat service to notify your Discord when the check goes silent."
  type        = string
}
