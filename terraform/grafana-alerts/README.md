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
   fixed roles this module actually needs:
   - **Alerting Writer** (`fixed:alerting.writer`) — alert rules + contact
     points + notification policy. (Splits into `fixed:alerting.rules:writer` +
     `fixed:alerting.notifications:writer` if you want to drop silences/instances.)
   - **Folder Creator** (`fixed:folders:creator`) — to create the "Homelab
     Alerts" folder and manage the rules in it. (Tighter: pre-create that folder
     and grant the SA **Edit on just that folder** instead.)

   Admin/Editor are **not** required — the module only touches alerting + one
   folder, reads no datasources (the UID is a var), and touches no dashboards,
   users, or org settings. Note contact points + the notification policy are
   org-global singletons, so org-level alerting-notifications write is the
   irreducible floor. Then **Add token** and copy it.
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
  -var 'discord_webhook_url=https://discord.com/api/webhooks/<id>/<token>' \
  -var 'deadmansswitch_webhook_url=https://hc-ping.com/<uuid>'
```

- `prometheus_datasource_uid` — Connections → Data sources in the stack
  (e.g. `grafanacloud-<org>-prom`).
- `discord_webhook_url` — a Discord channel webhook (Server Settings →
  Integrations → Webhooks). Real alerts post here.
- `deadmansswitch_webhook_url` — a heartbeat check URL (healthchecks.io, Grafana
  OnCall heartbeat, Better Uptime…). It must alarm when pings **stop**; a Discord
  webhook won't work directly, because the signal is absence. Configure the
  heartbeat service to notify your Discord on a missed check.

## Deployment precedence

Two orderings matter here, and they're independent.

### Apply order (Terraform dependency graph)

Terraform derives this from resource references, not file order:

1. `data.vault_kv_secret_v2.grafana_cloud` is read first — the `grafana`
   provider is configured from it (`stack_url` + `stack_sa_token`), so nothing
   Grafana-side can run until Vault resolves and returns the secret. This is why
   `vault.lab.hezebonica.ca` must be resolving before you apply.
2. In parallel: the `Homelab Alerts` folder and both contact points
   (`homelab-default`, `homelab-deadmansswitch`) — none depend on each other.
3. `grafana_notification_policy.root` — waits on **both** contact points (it
   references their `.name`).
4. `grafana_rule_group.homelab` — waits on the folder (`folder_uid`).

### Routing precedence (which policy wins)

The notification policy tree is evaluated top-down; the most specific matching
child wins and can terminate routing:

- `DeadMansSwitch` matches the child policy → routed to
  `homelab-deadmansswitch` (the heartbeat webhook) **only**. `continue = false`
  stops evaluation there, so it never falls through to Discord.
- Every other alert matches no child → falls through to the root default
  (`homelab-default`) → Discord.

Presence-based infra alerts go to Discord; the absence-based dead-man's-switch
goes to the one receiver that can detect silence.

## Notes

- `grafana_notification_policy` is a **singleton** — it replaces the stack's
  root notification policy tree. Fine for a single-tenant homelab; be aware if
  you later hand-edit routing in the UI (Terraform will revert it).
- Resources created here are provenance-marked, so they're read-only in the
  Grafana UI (edit them in Terraform).
