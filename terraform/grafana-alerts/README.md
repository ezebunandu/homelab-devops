# terraform/grafana-alerts

Homelab alerting as code: Grafana-managed alert rules + contact points +
notification routing in the Grafana Cloud stack. Rules query the stack's
Prometheus (Mimir) datasource, which the `k8s-monitoring` chart and PVE Alloy
already feed.

## What it creates

- A **dead-man's-switch** rule (always firing) routed to a heartbeat receiver —
  if the pings stop, the telemetry pipeline is down.
- Starter infra alerts: `KubeNodeNotReady`, `KubePodCrashLooping`,
  `KubePersistentVolumeFillingUp`, `KubeControlPlaneTargetDown`.
- A Discord contact point for real alerts + a notification policy that sends the
  DMS to a heartbeat receiver and everything else to Discord.

### Why the DMS isn't a Discord webhook

A dead-man's-switch detects failure by its alert **stopping**. Discord (like any
fire-and-forget webhook) has no notion of "a message I expected didn't arrive" —
so if the DMS posted straight to Discord, a dead pipeline would just go quiet and
nobody would be alarmed. Instead the DMS pings a heartbeat monitor
(healthchecks.io / Grafana OnCall / Better Uptime); that service watches for
absence and notifies your Discord when the pings stop. Real alerts fire on
presence, so those go to Discord directly.

## One-time bootstrap (why, and how)

Managing alert rules happens against the **stack's Grafana API**, which the
Cloud `accesspolicies:write` management token does **not** authorize. So this
module authenticates with a **stack service-account token** read from Vault,
rather than coupling alerting to the broader-privilege cloud token.

Create it once and store it in Vault:

1. In the stack: **Administration → Users and access → Service accounts →
   Add**. Use **least privilege** — set **No basic role**, then attach the
   fixed roles this module actually needs. NB: the Terraform provider manages
   alerting via the **provisioning API** (`/api/v1/provisioning/*`), which is
   gated by `alert.provisioning:*` — NOT the interactive alerting permissions.
   So the required roles are:
   - **Alerting Provisioning Writer** (`fixed:alerting.provisioning:writer`) —
     grants `alert.provisioning:read`/`write` for contact points, the
     notification policy, and rule groups. (The interactive `fixed:alerting.writer`
     does **not** cover the provisioning API — using it fails with 403 on
     `POST /v1/provisioning/contact-points`.)
   - **Folder Writer** (`fixed:folders:writer`) — create **and read** the
     "Homelab Alerts" folder. (`fixed:folders:creator` alone lacks `folders:read`
     and fails the folder GET with 403.)
   - Only if a later plan shows a perpetual diff on the secret webhook URLs, add
     **Alerting Provisioning Secrets Reader**
     (`fixed:alerting.provisioning.secrets:reader`) so the provider can read
     secret contact-point fields back to compare.

   Admin/Editor are **not** required — the module only touches alerting + one
   folder, reads no datasources (the UID is a var), and touches no dashboards,
   users, or org settings. Then **Add token** and copy it.
2. Store it, plus the stack's Grafana URL, in the existing Vault secret:
   ```bash
   vault kv patch secret/grafana-cloud \
     stack_url='https://<your-stack>.grafana.net' \
     stack_sa_token='<service-account-token>'
   ```
   (A future improvement is to mint this SA + token in `terraform/grafana-cloud`
   with `grafana_cloud_stack_service_account{,_token}` — deferred; that needs a
   cloud token with `stack-service-accounts:write`.)

## Apply

```bash
export VAULT_ADDR=https://vault.lab.hezebonica.ca
export VAULT_TOKEN=<token>

terraform init
terraform apply \
  -var 'prometheus_datasource_uid=<mimir-ds-uid>' \
  -var 'loki_datasource_uid=<loki-ds-uid>' \
  -var 'discord_webhook_url=https://discord.com/api/webhooks/<id>/<token>' \
  -var 'deadmansswitch_webhook_url=https://hc-ping.com/<uuid>'
```

- `prometheus_datasource_uid` — Connections → Data sources in the stack
  (e.g. `grafanacloud-<org>-prom`).
- `loki_datasource_uid` — same page (e.g. `grafanacloud-<org>-logs`). Used by
  the "Security Detections" folder's native Falco rule; the same UID also
  goes into `homelab-detections`' `config.yml` for the Sigma-provisioned
  rules. After apply, `terraform output security_detections_folder_id` gives
  the numeric folder ID that config.yml's `integration.folder_id` needs.
- `discord_webhook_url` — a Discord channel webhook (Server Settings →
  Integrations → Webhooks). Real alerts post here.
- `deadmansswitch_webhook_url` — a heartbeat check URL (healthchecks.io, Grafana
  OnCall heartbeat, Better Uptime…). It must alarm when pings **stop**; a Discord
  webhook won't work directly, because the signal is absence. Configure the
  heartbeat service to notify your Discord on a missed check.