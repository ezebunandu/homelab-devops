# ============================================================================
# Grafana Cloud ingest credential management for the homelab.
#
# Single home for the write-only Access Policies + tokens that let each
# telemetry source push to Grafana Cloud. Reads the shared endpoints + the
# accesspolicies:write management token from Vault, mints a separate policy per
# source (so any one source can be revoked/rotated in isolation), and writes
# each ingest token — with the shared, already-push-suffixed endpoints — back
# to Vault for consumers.
#
# NOTE: the PVE-host source currently mints its own policy inline in
# terraform/pve-observability/. It should migrate here for consistency; that's
# deferred because moving it regenerates the token (a one-time re-provision of
# the PVE Alloy hosts). New sources land here from the start.
# ============================================================================

data "vault_kv_secret_v2" "grafana_cloud" {
  mount = "secret"
  name  = var.vault_secret_path
}

# ── In-cluster Kubernetes observability (k8s-monitoring chart) ───────────────
# Write-only policy, independent of PVE. Same stack, so the per-signal instance
# IDs (usernames) and endpoint URLs are reused from the shared Vault secret;
# only the token is source-specific.
# Rotate with:  terraform apply -replace=grafana_cloud_access_policy_token.k8s
resource "grafana_cloud_access_policy" "k8s" {
  region       = var.grafana_cloud_region
  name         = "k8s-observability-write"
  display_name = "Kubernetes observability (write-only)"

  scopes = ["metrics:write", "logs:write"]

  realm {
    type       = "stack"
    identifier = var.grafana_cloud_stack_id
  }
}

resource "grafana_cloud_access_policy_token" "k8s" {
  region           = var.grafana_cloud_region
  access_policy_id = grafana_cloud_access_policy.k8s.policy_id
  name             = "k8s-observability"
  display_name     = "Kubernetes observability"
}

# Write-back to Vault for the homelab-platform ExternalSecret to consume
# (ClusterSecretStore "vault", remoteRef.key "platform/grafana-cloud-k8s").
# URLs are already push-suffixed correctly in the source secret
# (metrics_url -> /api/prom/push, logs_url -> /loki/api/v1/push).
resource "vault_kv_secret_v2" "k8s_grafana_cloud" {
  mount = "secret"
  name  = "platform/grafana-cloud-k8s"

  data_json = jsonencode({
    metrics_url      = data.vault_kv_secret_v2.grafana_cloud.data["metrics_url"]
    metrics_username = data.vault_kv_secret_v2.grafana_cloud.data["metrics_username"]
    logs_url         = data.vault_kv_secret_v2.grafana_cloud.data["logs_url"]
    logs_username    = data.vault_kv_secret_v2.grafana_cloud.data["logs_username"]
    # Host-only variant (no /loki/api/v1/push suffix) for consumers that split
    # host and path themselves — falcosidekick's LOKI_HOSTPORT expects
    # scheme://host:port and appends its own `endpoint` (default the same
    # suffix), so feeding it the full push URL would double the path.
    logs_host = replace(data.vault_kv_secret_v2.grafana_cloud.data["logs_url"], "/loki/api/v1/push", "")
    token     = grafana_cloud_access_policy_token.k8s.token
  })
}
