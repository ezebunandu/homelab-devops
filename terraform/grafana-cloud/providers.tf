# Vault provider reads VAULT_ADDR and VAULT_TOKEN from the environment.
# Expose Vault before apply (now reachable on the LAN):
#
#   export VAULT_ADDR=https://vault.lab.hezebonica.ca
#   export VAULT_TOKEN=<token>
#
# (or port-forward: kubectl port-forward svc/vault -n vault 8200:8200 &
#  export VAULT_ADDR=http://localhost:8200)
provider "vault" {}

# Grafana Cloud provider, authed with a management token (scope
# accesspolicies:write) stored in Vault. This module mints the per-source,
# write-only ingest access policies + tokens for the whole homelab.
provider "grafana" {
  cloud_access_policy_token = data.vault_kv_secret_v2.grafana_cloud.data["management_token"]
}
