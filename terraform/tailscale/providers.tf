# Vault provider reads VAULT_ADDR and VAULT_TOKEN from the environment.
# Before running terraform apply, expose Vault from the cluster:
#
#   kubectl port-forward svc/vault -n vault 8200:8200 &
#   export VAULT_ADDR=http://localhost:8200
#   export VAULT_TOKEN=<token>
provider "vault" {}
