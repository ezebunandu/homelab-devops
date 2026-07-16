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

  # Baseline auditd ruleset, Sigma linux_auditd-oriented. Execve is the backbone
  # of most TTP detections (high volume, accepted — Grafana Cloud Pro). Watches
  # cover identity, sudo, ssh, kernel modules, cron/persistence, and time.
  audit_rules = <<-EOT
    ## Homelab baseline audit ruleset — managed by terraform/pve-observability
    -D
    -b 8192
    -f 1
    ## Identity / auth
    -w /etc/passwd -p wa -k identity
    -w /etc/shadow -p wa -k identity
    -w /etc/group -p wa -k identity
    -w /etc/sudoers -p wa -k identity
    -w /etc/sudoers.d/ -p wa -k identity
    -w /etc/ssh/sshd_config -p wa -k sshd
    ## Privilege escalation (execve where euid=0 but uid differs)
    -a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k privesc
    ## Process execution
    -a always,exit -F arch=b64 -S execve -k exec
    -a always,exit -F arch=b32 -S execve -k exec
    ## Kernel modules
    -a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules
    -w /sbin/insmod -p x -k modules
    -w /sbin/modprobe -p x -k modules
    ## Cron / persistence
    -w /etc/crontab -p wa -k cron
    -w /etc/cron.d/ -p wa -k cron
    ## Time changes
    -a always,exit -F arch=b64 -S adjtimex,settimeofday -k time
  EOT

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
    audit_rules_hash = sha256(local.audit_rules)
  }

  connection {
    type  = "ssh"
    host  = each.value
    user  = "root"
    agent = true
  }

  # Create /etc/alloy BEFORE the file provisioners run — Terraform's file
  # provisioner does not create parent directories, so without this the configs
  # get written to a regular file literally named /etc/alloy. Also clears that
  # stray file if a prior failed run left one behind (mkdir -p can't replace it).
  provisioner "remote-exec" {
    inline = [
      "set -eu",
      "[ -f /etc/alloy ] && rm -f /etc/alloy || true",
      "mkdir -p /etc/alloy /var/lib/alloy",
      "chmod 700 /etc/alloy",
      "# Install auditd so /etc/audit/rules.d exists before the rules file lands.",
      "command -v auditctl >/dev/null 2>&1 || { apt-get update -qq || true; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq auditd; }",
    ]
  }

  # Baseline audit ruleset → auditd loads everything under /etc/audit/rules.d.
  provisioner "file" {
    content     = local.audit_rules
    destination = "/etc/audit/rules.d/homelab.rules"
  }

  # Load the ruleset and ensure auditd is running/enabled. augenrules compiles
  # rules.d into the active policy; auditd must be restarted (not reloaded) to
  # pick up new watches/syscall rules.
  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "augenrules --load",
      "systemctl enable auditd",
      "systemctl restart auditd",
      "auditctl -l >/dev/null || { echo 'auditd rules failed to load'; exit 1; }",
    ]
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
      "# Install binary if version differs",
      "INSTALLED=$(alloy --version 2>/dev/null | awk '{print $3}' || echo none)",
      "TARGET=v${var.alloy_version}",
      "if [ \"$INSTALLED\" != \"$TARGET\" ]; then",
      "  echo \"Installing Alloy $TARGET (installed: $INSTALLED)\"",
      "  # Proxmox ships without unzip; install it (tolerate a noisy apt-get update on no-subscription hosts).",
      "  command -v unzip >/dev/null 2>&1 || { apt-get update -qq || true; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip; }",
      "  curl -fsSL https://github.com/grafana/alloy/releases/download/$TARGET/alloy-linux-amd64.zip -o /tmp/alloy.zip",
      "  cd /tmp && unzip -o alloy.zip alloy-linux-amd64",
      "  install -m 755 /tmp/alloy-linux-amd64 /usr/local/bin/alloy",
      "  rm -f /tmp/alloy.zip /tmp/alloy-linux-amd64",
      "fi",
      "systemctl daemon-reload",
      "systemctl enable alloy",
      "systemctl restart alloy",
      # Type=simple returns success at exec; settle, then verify it's truly up
      # (a config error crash-loops, which a bare is-active would miss) and that
      # the OTLP receiver is bound before the metric-server step tests it.
      "sleep 3",
      "systemctl is-active --quiet alloy || { journalctl -u alloy --no-pager -n 30; exit 1; }",
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
