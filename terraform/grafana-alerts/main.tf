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

  # Query-volume anomaly. The correlator polls Grafana Cloud for firing
  # alerts rather than receiving a pushed webhook (no Tailscale/Funnel, no
  # inbound exposure at all — see docs/query-volume-anomaly-plan.md), so this
  # is the only notification wiring this alert needs: get a human notified.
  # Shorter repeat_interval than the root policy's inherited 4h: an
  # ongoing/recurring spike should keep getting re-flagged, unlike the infra
  # alerts below where one notification per incident is enough.
  policy {
    matcher {
      label = "source"
      match = "="
      value = "query-anomaly"
    }
    contact_point   = grafana_contact_point.default.name
    repeat_interval = "30m"
    continue        = false
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
  #
  # no_data_state = OK (not NoData, unlike the Prometheus rules above/below):
  # this is a Loki count_over_time query filtered on priority=~Critical|Error|
  # Warning. When A1-A3's tuning is working (no findings in the last 5m), Loki
  # returns NO SERIES at all for that filter -- structurally different from a
  # Prometheus sum() query, which always returns a defined value (even zero)
  # as long as the base metric exists. Treating that as NoData meant a quiet,
  # healthy Falco fired a repeating DatasourceNoData alert every ~5m instead
  # of just... not alerting. "No data" here means "nothing bad happened",
  # which is the same case DeadMansSwitch already handles this way below.
  rule {
    name           = "FalcoCriticalOrErrorFinding"
    condition      = "C"
    for            = "0s"
    no_data_state  = "OK"
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

# ── Query-volume anomaly detection ────────────────────────────────────────────
# Own folder, deliberately separate from both "Homelab Alerts" (infra/hardware
# health) and "Security Detections" (Loki-native Sigma/Falco rules) — this
# rule's mechanics match "Homelab Alerts"'s Prometheus-threshold pattern, but
# its intent (catching a leaked-token/compromised-account-driven spike) is
# distinct enough from both to warrant its own home.
resource "grafana_folder" "query_volume_anomaly" {
  title = "Query Volume Anomaly"
}

# Forecasts the stack's own read-query volume straight off usage-insights
# query-event counts (datasource_type = "loki" is supported — confirmed
# against the provider's resource schema, not just its docs, which only show
# Prometheus examples). No need to guess a Prometheus "queries per second"
# metric name that was never confirmed to exist on this stack's
# grafanacloud-usage datasource. datasource_uid is the *UID*, not the display
# name — for this provisioned datasource they differ (UID has no stack slug:
# "grafanacloud-usage-insights", vs. display name
# "grafanacloud-<stack>-usage-insights" — confirmed the hard way, via a
# "Data source not found" training error).
resource "grafana_machine_learning_job" "query_volume_forecast" {
  name            = "Query Volume Forecast"
  metric          = "query_volume_forecast"
  description     = "Forecasts the stack's read-query volume from usage-insights, for anomaly alerting."
  datasource_type = "loki"
  datasource_uid  = var.usage_insights_datasource_uid

  # Confirmed against a real usage-insights log line in Explore: this
  # datasource has no "job" indexed label at all (that was a guess from the
  # original write-up and matched nothing — the ML job trained "ready" but
  # warned "No series to train"). The real indexed labels are instance_id,
  # instance_type, org_id, service_name; service_name="grafana" matches every
  # entry seen so far. eventName="data-request" (unquoted in the raw
  # logfmt line, e.g. `eventName=data-request`) was already correct — logfmt
  # parsing normalizes quoted/unquoted values the same way.
  #
  # sum(...) is required, not cosmetic: `| logfmt` extracts every field on
  # the line (panelId, dashboardUid, tokenId, duration, ...) as its own
  # label, so an unaggregated count_over_time produces one series per unique
  # label combination — with high-cardinality fields like panelId/duration
  # in the mix, that's close to one series per log line, which blew past
  # Loki's 5000-series-per-query cap over the 30d training window. sum()
  # collapses everything to the single total-volume series we actually want
  # to forecast (total query volume, not broken out per panel/user/token).
  query_params = {
    expr = "sum(count_over_time({service_name=\"grafana\"} | logfmt | eventName=\"data-request\" [5m]))"
  }

  training_window = 2592000 # 30d
}

resource "grafana_rule_group" "query_volume_anomaly" {
  name             = "query-volume-anomaly"
  folder_uid       = grafana_folder.query_volume_anomaly.uid
  interval_seconds = 60

  rule {
    name = "QueryVolumeAnomaly"
    # Immediate detection over debounce, deliberately — revisit with a `for`
    # window (e.g. "5m") if the ML forecast band proves noisy enough to
    # false-positive once deployed.
    condition = "C"
    for       = "0s"
    # no_data_state = OK, not NoData (unlike most Prometheus rules in this
    # file): observed in testing that grafanacloud-ml-metrics' actual/
    # predicted series have real gaps in normal operation (the ML job's
    # forecast-metric publish cadence isn't perfectly continuous), which
    # otherwise fires a synthetic DatasourceNoData alert every time — it
    # still carries this rule's source=query-anomaly label, so it routed to
    # Discord just as noisily as a real firing would, on a condition with no
    # anomaly meaning at all. Same trade-off already accepted for the Falco
    # rule below (main.tf:115): if the whole ML/usage-insights pipeline dies
    # outright, this stays silently OK rather than paging — a known gap, not
    # a fix for pipeline-health monitoring, just for this exact noise.
    no_data_state  = "OK"
    exec_err_state = "Error"

    data {
      ref_id         = "A"
      datasource_uid = var.ml_metrics_datasource_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      # Confirmed syntax from Grafana Cloud's "Alerting on forecasts" doc:
      # compare the forecast's :actual series against its own :predicted
      # upper-bound series, ignoring the ml_forecast label that otherwise
      # makes the two series' label sets mismatch.
      model = jsonencode({
        refId         = "A"
        expr          = "query_volume_forecast:actual > bool ignoring(ml_forecast) query_volume_forecast:predicted{ml_forecast=\"yhat_upper\"}"
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

    labels      = { severity = "warning", source = "query-anomaly" }
    annotations = { summary = "Read-query volume has crossed the forecast's upper bound." }
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

  # ── Proxmox host hardware/operational alerts ─────────────────────────────
  # PVE hosts push node_exporter-equivalent metrics via the Alloy
  # prometheus.exporter.unix component (terraform/pve-observability) with no
  # set_collectors override, so hwmon/thermal/cpu/meminfo/diskstats are all
  # enabled by default (confirmed against Alloy's own docs). Every query is
  # scoped to cluster="devops-cluster" specifically, since Talos nodes expose
  # the *same* node_exporter metric names via k8s-monitoring's hostMetrics
  # feature under cluster="homelab-talos" — without this scope these would
  # silently blend PVE hosts and k8s nodes together.

  # A CPU/board/NVMe sensor is reporting a high temperature. Unions hwmon +
  # thermal_zone (ACPI) so this reflects the same full picture as the
  # existing "Node Thermal Monitoring" dashboard, not just one metric source.
  # Thresholds calibrated against real live data (2026-07-20): the MS-A2
  # (devops) normally peaks ~73.5°C, the two Lenovo M910qs (devops2/devops3)
  # normally run cooler at 62-65°C. Unscoped across all sensors per instance
  # (chip/sensor labels vary by hardware, and NVMe drives legitimately run
  # warm) -- tighten to specific sensors if a particular one proves noisy.
  rule {
    name           = "PVEHostCPUTemperatureWarning"
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
        expr          = "sum(max by (instance) (node_hwmon_temp_celsius{cluster=\"devops-cluster\"} or node_thermal_zone_temp{cluster=\"devops-cluster\"}) > bool 82)"
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
    annotations = { summary = "A PVE host hardware sensor has been above 82°C for 10m — worth a look, well below throttle margin." }
  }

  rule {
    name           = "PVEHostCPUTemperatureCritical"
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
        expr          = "sum(max by (instance) (node_hwmon_temp_celsius{cluster=\"devops-cluster\"} or node_thermal_zone_temp{cluster=\"devops-cluster\"}) > bool 90)"
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
    annotations = { summary = "A PVE host hardware sensor has been above 90°C for 5m — approaching throttle territory." }
  }

  # Sustained high CPU utilization (traditional %busy, not PSI) -- 15m grace
  # period since PVE hosts running VMs legitimately burst CPU often.
  rule {
    name           = "PVEHostCPUUsageHigh"
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
        expr          = "sum((100 - (avg by (instance) (rate(node_cpu_seconds_total{cluster=\"devops-cluster\", mode=\"idle\"}[5m])) * 100)) > bool 90)"
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
    annotations = { summary = "A PVE host has been above 90% CPU utilization for 15m." }
  }

  # Sustained high memory utilization.
  rule {
    name           = "PVEHostMemoryUsageHigh"
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
        expr          = "sum(((1 - (node_memory_MemAvailable_bytes{cluster=\"devops-cluster\"} / node_memory_MemTotal_bytes{cluster=\"devops-cluster\"})) * 100) > bool 90)"
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
    annotations = { summary = "A PVE host has been above 90% memory utilization for 15m." }
  }

  # A PVE host's root/local-storage filesystem is under 10% free. Excludes
  # pseudo-filesystems (same intent as excluding tmpfs from disk pressure
  # elsewhere) -- real local storage only.
  rule {
    name           = "PVEHostDiskSpaceLow"
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
        expr          = "sum((node_filesystem_avail_bytes{cluster=\"devops-cluster\", fstype!~\"tmpfs|overlay|squashfs|devtmpfs\"} / node_filesystem_size_bytes{cluster=\"devops-cluster\", fstype!~\"tmpfs|overlay|squashfs|devtmpfs\"}) < bool 0.10)"
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
    annotations = { summary = "A PVE host filesystem has been below 10% free space for 15m." }
  }
}

