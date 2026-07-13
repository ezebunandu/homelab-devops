# Vault provider reads VAULT_ADDR and VAULT_TOKEN from the environment.
#
#   export VAULT_ADDR=https://vault.lab.hezebonica.ca
#   export VAULT_TOKEN=<token>
provider "vault" {}

# Grafana provider pointed at the STACK's Grafana API (not the Cloud API).
# Managing alert rules / contact points / notification policies happens against
# the stack itself, which the Cloud "accesspolicies:write" management token does
# NOT authorize. So this authenticates with a stack service-account token
# (role: Admin or Editor) read from Vault. See README.md for the one-time
# bootstrap that creates that SA token and stores it in Vault.
provider "grafana" {
  url  = data.vault_kv_secret_v2.grafana_cloud.data["stack_url"]
  auth = data.vault_kv_secret_v2.grafana_cloud.data["stack_sa_token"]
}
