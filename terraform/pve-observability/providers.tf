# Vault provider reads VAULT_ADDR and VAULT_TOKEN from the environment.
# Before running terraform apply, expose Vault from the cluster:
#
#   kubectl port-forward svc/vault -n vault 8200:8200 &
#   export VAULT_ADDR=http://localhost:8200
#   export VAULT_TOKEN=<root-or-scoped-token>
provider "vault" {}

# Grafana Cloud provider — used only to mint the write-only ingest access
# policy + token for this telemetry source. Authenticated with a management
# token (scope: accesspolicies:write) stored in Vault alongside the Grafana
# Cloud endpoints. The provider talks to grafana.com; per-resource `region`
# selects the stack's deployment region.
provider "grafana" {
  cloud_access_policy_token = data.vault_kv_secret_v2.grafana_cloud.data["management_token"]
}
