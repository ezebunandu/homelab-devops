data "vault_kv_secret_v2" "grafana_cloud" {
  mount = "secret"
  name  = var.vault_secret_path
}

locals {
  # Rendered Alloy config per host — used for trigger hash and file provisioner.
  alloy_configs = {
    for hostname, ip in var.pve_hosts :
    hostname => templatefile("${path.module}/templates/alloy-config.alloy.tftpl", {
      hostname = hostname
    })
  }

  # Hash of all Grafana Cloud credential values — triggers re-provisioning on rotation.
  credentials_hash = sha256(join("\n", [
    data.vault_kv_secret_v2.grafana_cloud.data["metrics_url"],
    data.vault_kv_secret_v2.grafana_cloud.data["metrics_username"],
    data.vault_kv_secret_v2.grafana_cloud.data["metrics_token"],
    data.vault_kv_secret_v2.grafana_cloud.data["logs_url"],
    data.vault_kv_secret_v2.grafana_cloud.data["logs_username"],
    data.vault_kv_secret_v2.grafana_cloud.data["logs_token"],
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
      "GRAFANA_CLOUD_METRICS_TOKEN=${data.vault_kv_secret_v2.grafana_cloud.data["metrics_token"]}",
      "GRAFANA_CLOUD_LOGS_URL=${data.vault_kv_secret_v2.grafana_cloud.data["logs_url"]}",
      "GRAFANA_CLOUD_LOGS_USERNAME=${data.vault_kv_secret_v2.grafana_cloud.data["logs_username"]}",
      "GRAFANA_CLOUD_LOGS_TOKEN=${data.vault_kv_secret_v2.grafana_cloud.data["logs_token"]}",
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
      "",
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
      "",
      "systemctl daemon-reload",
      "systemctl enable alloy",
      "systemctl restart alloy",
      "systemctl is-active alloy",
    ]
  }
}
