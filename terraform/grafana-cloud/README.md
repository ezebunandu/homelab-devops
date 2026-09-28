# terraform/grafana-cloud

Central home for the write-only and read-only Access Policies + tokens that
let each telemetry source push to (or, for the correlator, read from)
Grafana Cloud. Mints a separate policy per source, so any one source can be
revoked/rotated in isolation, and writes each token back to Vault for
consumers (currently: homelab-platform's ExternalSecrets).

## One-time bootstrap (why, and how)

Two Vault secrets are manually pre-seeded rather than minted by this module,
because they hold values Terraform has no way to generate or fetch on its
own — Terraform only merges them with what it *does* mint (access-policy
tokens) before writing the combined result back to Vault for consumers.

- `secret/grafana-cloud` — the stack's ingest endpoints/usernames and the
  Cloud `accesspolicies:write` management token this module authenticates
  with. Pre-existing; not covered here.
- `secret/correlator-bootstrap` — the query-volume-anomaly correlator's
  non-Grafana-Cloud secrets. The correlator polls Grafana Cloud's Alerting
  API for firing anomaly alerts rather than receiving a pushed webhook (no
  Tailscale/Funnel, no inbound exposure of any kind), so all it needs beyond
  its own minted Cloud Access Policy token is somewhere to post to and a way
  to read alert state. Seed once by hand:

  ```bash
  vault kv put secret/correlator-bootstrap \
    discord_webhook_url=<same Discord webhook URL as grafana-alerts' discord_webhook_url var — reused, not separate> \
    grafana_stack_alert_reader_token=<stack-level Grafana service account token, READ-ONLY — see role below>
  ```

  Create that service account with **no basic role**, then attach only the
  **"Instances and Silences Reader"** fixed role (internal ID
  `fixed:alerting.instances:reader`, grants `alert.instances:read` — that
  display name is what shows up in the role picker; the internal ID doesn't
  appear there directly, confirmed against Grafana's own RBAC fixed-role
  reference).

  `grafana_stack_alert_reader_token` is deliberately a **separate, narrower**
  credential from `terraform/grafana-alerts`' own `stack_sa_token` (which has
  `alerting.provisioning:writer` + `folders:writer` — the correlator never
  needs to write alerting config, only read current alert state).

  `terraform/grafana-cloud` reads this, merges in the access-policy token it
  mints plus `stack_url` (already read from `secret/grafana-cloud`), and
  writes the combined secret to `secret/platform/correlator` (the path
  homelab-platform's ExternalSecret reads from). It is the **sole writer**
  of that path.

## Apply

```bash
export VAULT_ADDR=https://vault.lab.hezebonica.ca
export VAULT_TOKEN=<token>

terraform init
terraform apply \
  -var 'grafana_cloud_region=<e.g. prod-us-east-0>' \
  -var 'grafana_cloud_stack_id=<numeric stack ID>'
```

Apply this module **before** `terraform/grafana-alerts` when standing up the
correlator for the first time — the correlator's Vault secret (and therefore
its ExternalSecret in homelab-platform) needs to exist before anything
downstream can consume it.
