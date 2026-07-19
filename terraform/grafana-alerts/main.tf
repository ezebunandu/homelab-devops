# ============================================================================
# Homelab alerting, as code — Grafana-managed alert rules + notification routing
# in the Grafana Cloud stack. Rules query the stack's Prometheus (Mimir)
# datasource, which the k8s-monitoring chart and PVE Alloy already feed.
#
# All rules are written to fire when their query is > 0, so they share one
# threshold shape (A: instant PromQL → B: reduce last → C: threshold gt 0).
# ============================================================================

data "vault_kv_secret_v2" "grafana_cloud" {
  mount = "secret"
  name  = var.vault_secret_path
}

resource "grafana_folder" "homelab" {
  title = "Homelab Alerts"
}

# ── Contact points ───────────────────────────────────────────────────────────
resource "grafana_contact_point" "default" {
  name = "homelab-default"

  discord {
    url = var.discord_webhook_url
  }
}

# The dead-man's-switch destination: a heartbeat receiver that alarms when the
# continuous DMS pings STOP arriving (telemetry pipeline down / WAN down).
# This is deliberately NOT a Discord webhook — Discord can't detect absence.
# Point it at a heartbeat service (healthchecks.io / OnCall / Better Uptime) and
# configure THAT service to notify Discord when the check goes silent.
resource "grafana_contact_point" "deadmansswitch" {
  name = "homelab-deadmansswitch"

  webhook {
    url = var.deadmansswitch_webhook_url
  }
}

# ── Notification policy (singleton — replaces the stack's root policy tree) ────
resource "grafana_notification_policy" "root" {
  group_by      = ["alertname"]
  contact_point = grafana_contact_point.default.name

  group_wait      = "30s"
  group_interval  = "5m"
  repeat_interval = "4h"

  # Route the dead-man's-switch to the heartbeat receiver, pinging every 5m.
  policy {
    matcher {
      label = "alertname"
      match = "="
      value = "DeadMansSwitch"
    }
    contact_point   = grafana_contact_point.deadmansswitch.name
    group_wait      = "0s"
    group_interval  = "5m"
    repeat_interval = "5m"
    continue        = false
  }

  # Security detections: Sigma-provisioned rules (homelab-detections repo,
  # labelled source="sigma" via config.yml's integration.template_labels) and
  # the native Falco rule below (labelled source="falco") share this route —
  # one exit path to the same Discord contact point as everything else.
  policy {
    matcher {
      label = "source"
      match = "=~"
      value = "sigma|falco"
    }
    contact_point = grafana_contact_point.default.name
    continue      = false
  }
}

# ── Security Detections (Loki-backed) ─────────────────────────────────────────
# Separate folder + rule group from "Homelab Alerts" above — different
# datasource (Loki, not Prometheus) and a distinct source: this is where
# Sigma-provisioned rules (homelab-detections repo) land, plus the one native
# rule below for Falco, which uses its own rule engine, not Sigma.
resource "grafana_folder" "security_detections" {
  title = "Security Detections"
}

resource "grafana_rule_group" "security_detections" {
  name             = "security-detections-native"
  folder_uid       = grafana_folder.security_detections.uid
  interval_seconds = 60

  # Falco findings exit through the same folder/notification path as Sigma
  # detections (security-detection-plan.md B5) via this one thin LogQL rule —
  # Sigma is not run over Falco's output, Falco already emits detections.
  rule {
    name           = "FalcoCriticalOrErrorFinding"
    condition      = "C"
    for            = "0s"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = var.loki_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId         = "A"
        expr          = "count_over_time({product=\"falco\"} | json | priority=~\"Critical|Error|Warning\" [5m])"
        instant       = true
        range         = false
        editorMode    = "code"
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "B"
        type       = "reduce"
        expression = "A"
        reducer    = "last"
      })
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "B"
        conditions = [{ evaluator = { type = "gt", params = [0] } }]
      })
    }

    labels      = { severity = "critical", source = "falco" }
    annotations = { summary = "Falco reported a Critical/Error/Warning finding in the last 5m." }
  }
}

# ── Rule group ────────────────────────────────────────────────────────────────
resource "grafana_rule_group" "homelab" {
  name             = "homelab-infra"
  folder_uid       = grafana_folder.homelab.uid
  interval_seconds = 60

  # Dead-man's-switch: always firing. Its VALUE is meaningless; its continued
  # ARRIVAL at the heartbeat receiver is the signal. If it stops, the pipeline
  # (Alloy, WAN, or Grafana Cloud) is down and the external receiver alarms.
  rule {
    name           = "DeadMansSwitch"
    condition      = "C"
    for            = "0s"
    no_data_state  = "OK"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId         = "A"
        expr          = "vector(1)"
        instant       = true
        range         = false
        editorMode    = "code"
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "B"
        type       = "reduce"
        expression = "A"
        reducer    = "last"
      })
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "B"
        conditions = [{ evaluator = { type = "gt", params = [0] } }]
      })
    }

    labels      = { severity = "none" }
    annotations = { summary = "Dead-man's-switch heartbeat — if this stops arriving, homelab telemetry is down." }
  }

  # A Kubernetes node is NotReady.
  rule {
    name           = "KubeNodeNotReady"
    condition      = "C"
    for            = "5m"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId         = "A"
        expr          = "sum(kube_node_status_condition{condition=\"Ready\",status=\"true\"} == bool 0)"
        instant       = true
        range         = false
        editorMode    = "code"
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "B"
        type       = "reduce"
        expression = "A"
        reducer    = "last"
      })
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "B"
        conditions = [{ evaluator = { type = "gt", params = [0] } }]
      })
    }

    labels      = { severity = "critical" }
    annotations = { summary = "One or more Kubernetes nodes have been NotReady for 5m." }
  }

  # Pods stuck in CrashLoopBackOff.
  rule {
    name           = "KubePodCrashLooping"
    condition      = "C"
    for            = "10m"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId         = "A"
        expr          = "sum(kube_pod_container_status_waiting_reason{reason=\"CrashLoopBackOff\"})"
        instant       = true
        range         = false
        editorMode    = "code"
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "B"
        type       = "reduce"
        expression = "A"
        reducer    = "last"
      })
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "B"
        conditions = [{ evaluator = { type = "gt", params = [0] } }]
      })
    }

    labels      = { severity = "warning" }
    annotations = { summary = "One or more pods have been crash-looping for 10m." }
  }

  # A PersistentVolume is under 10% free (kubelet volume stats).
  rule {
    name           = "KubePersistentVolumeFillingUp"
    condition      = "C"
    for            = "15m"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId         = "A"
        expr          = "sum((kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes) < bool 0.10)"
        instant       = true
        range         = false
        editorMode    = "code"
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "B"
        type       = "reduce"
        expression = "A"
        reducer    = "last"
      })
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "B"
        conditions = [{ evaluator = { type = "gt", params = [0] } }]
      })
    }

    labels      = { severity = "warning" }
    annotations = { summary = "A PersistentVolume is below 10% free space." }
  }

  # A scraped control-plane / apiserver target is down.
  rule {
    name           = "KubeControlPlaneTargetDown"
    condition      = "C"
    for            = "10m"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId         = "A"
        expr          = "sum(up{job=~\"kube-scheduler|kube-controller-manager|integrations/kubernetes/kube-apiserver\"} == bool 0)"
        instant       = true
        range         = false
        editorMode    = "code"
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }
    data {
      ref_id         = "B"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "B"
        type       = "reduce"
        expression = "A"
        reducer    = "last"
      })
    }
    data {
      ref_id         = "C"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "C"
        type       = "threshold"
        expression = "B"
        conditions = [{ evaluator = { type = "gt", params = [0] } }]
      })
    }

    labels      = { severity = "critical" }
    annotations = { summary = "A control-plane scrape target (apiserver/scheduler/controller-manager) has been down for 10m." }
  }
}
