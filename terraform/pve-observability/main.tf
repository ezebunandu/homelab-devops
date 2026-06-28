data "vault_kv_secret_v2" "grafana_cloud" {
  mount = "secret"
  name  = var.vault_secret_path
}

# ── Grafana Cloud ingest credential (minted as code) ─────────────────────────
# A dedicated, write-only access policy for the Proxmox telemetry source.
# One token covers both metrics and logs ingestion; the per-signal endpoints
# and usernames (instance IDs) still come from Vault. Keeping this policy
# separate from other sources (e.g. k8s) means it can be revoked/rotated in
# isolation. Rotate the token with:  terraform apply -replace=grafana_cloud_access_policy_token.pve
resource "grafana_cloud_access_policy" "pve" {
  region       = var.grafana_cloud_region
  name         = "pve-observability-write"
  display_name = "Proxmox observability (write-only)"

  scopes = ["metrics:write", "logs:write"]

  realm {
    type       = "stack"
    identifier = var.grafana_cloud_stack_id
  }
}

resource "grafana_cloud_access_policy_token" "pve" {
  region           = var.grafana_cloud_region
  access_policy_id = grafana_cloud_access_policy.pve.policy_id
  name             = "pve-observability"
  display_name     = "Proxmox observability"
}

locals {
  # Rendered Alloy config per host — used for trigger hash and file provisioner.
  alloy_configs = {
    for hostname, ip in var.pve_hosts :
    hostname => templatefile("${path.module}/templates/alloy-config.alloy.tftpl", {
      hostname = hostname
    })
  }

  # Hash of all Grafana Cloud credential values — triggers re-provisioning on
  # rotation. The single write token is sourced from the minted access policy,
  # so replacing the token resource re-provisions every host automatically.
  credentials_hash = sha256(join("\n", [
    data.vault_kv_secret_v2.grafana_cloud.data["metrics_url"],
    data.vault_kv_secret_v2.grafana_cloud.data["metrics_username"],
    data.vault_kv_secret_v2.grafana_cloud.data["logs_url"],
    data.vault_kv_secret_v2.grafana_cloud.data["logs_username"],
    grafana_cloud_access_policy_token.pve.token,
  ]))
}

resource "null_resource" "alloy_pve" {
  for_each = var.pve_hosts

  triggers = {
    alloy_version    = var.alloy_version
    config_hash      = sha256(local.alloy_configs[each.key])
    credentials_hash = local.credentials_hash
  }

  connection {
    type  = "ssh"
    host  = each.value
    user  = "root"
    agent = true
  }

  # Write Grafana Cloud credentials as an env file.
  # The systemd unit references this via EnvironmentFile= so values never
  # appear in the Alloy config or in process arguments.
  provisioner "file" {
    content = sensitive(join("\n", [
      "GRAFANA_CLOUD_METRICS_URL=${data.vault_kv_secret_v2.grafana_cloud.data["metrics_url"]}",
      "GRAFANA_CLOUD_METRICS_USERNAME=${data.vault_kv_secret_v2.grafana_cloud.data["metrics_username"]}",
      "GRAFANA_CLOUD_LOGS_URL=${data.vault_kv_secret_v2.grafana_cloud.data["logs_url"]}",
      "GRAFANA_CLOUD_LOGS_USERNAME=${data.vault_kv_secret_v2.grafana_cloud.data["logs_username"]}",
      # Single write-only token (metrics:write + logs:write) for both signals.
      "GRAFANA_CLOUD_TOKEN=${grafana_cloud_access_policy_token.pve.token}",
    ]))
    destination = "/etc/alloy/grafana-cloud.env"
  }

  # Write the rendered Alloy config.
  provisioner "file" {
    content     = local.alloy_configs[each.key]
    destination = "/etc/alloy/config.alloy"
  }

  # Write the systemd unit.
  provisioner "file" {
    source      = "${path.module}/templates/alloy.service"
    destination = "/etc/systemd/system/alloy.service"
  }

  # Install Alloy binary if absent or version differs, then start the service.
  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "mkdir -p /etc/alloy /var/lib/alloy",
      "chmod 700 /etc/alloy",
      "# Install binary if version differs",
      "INSTALLED=$(alloy --version 2>/dev/null | awk '{print $3}' || echo none)",
      "TARGET=v${var.alloy_version}",
      "if [ \"$INSTALLED\" != \"$TARGET\" ]; then",
      "  echo \"Installing Alloy $TARGET (installed: $INSTALLED)\"",
      "  curl -fsSL https://github.com/grafana/alloy/releases/download/$TARGET/alloy-linux-amd64.zip -o /tmp/alloy.zip",
      "  cd /tmp && unzip -o alloy.zip alloy-linux-amd64",
      "  install -m 755 /tmp/alloy-linux-amd64 /usr/local/bin/alloy",
      "  rm -f /tmp/alloy.zip /tmp/alloy-linux-amd64",
      "fi",
      "systemctl daemon-reload",
      "systemctl enable alloy",
      "systemctl restart alloy",
      "systemctl is-active alloy",
    ]
  }
}

# ── Proxmox external metric server (PVE 9 native OpenTelemetry) ──────────────
# Cluster-wide config lives in /etc/pve/status.cfg (replicated by pmxcfs), so
# this only needs to run on one node. Pointing at 127.0.0.1 makes every node's
# pvestatd push its own metrics to its own local Alloy OTLP receiver (:4318).
# Depends on the per-host Alloy roll-out so the receiver is listening first.
resource "null_resource" "pve_metric_server" {
  depends_on = [null_resource.alloy_pve]

  triggers = {
    # Re-applies if the target endpoint changes.
    endpoint = "127.0.0.1:4318/v1/metrics"
  }

  connection {
    type  = "ssh"
    host  = values(var.pve_hosts)[0]
    user  = "root"
    agent = true
  }

  # Delete-then-create keeps the entry idempotent and always matching desired
  # params (create is POST and rejects an existing id; this avoids drift).
  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "pvesh delete /cluster/metrics/server/alloy 2>/dev/null || true",
      "pvesh create /cluster/metrics/server/alloy \\",
      "  --type opentelemetry \\",
      "  --server 127.0.0.1 \\",
      "  --port 4318 \\",
      "  --otel-protocol http \\",
      "  --otel-path /v1/metrics \\",
      "  --otel-compression gzip",
      "pvesh get /cluster/metrics/server/alloy",
    ]
  }
}
