# GKE Autopilot sends system metrics to Cloud Monitoring on its own, so alerting policies on
# node CPU and container restarts need no extra agent. alert_email, when set, gets a
# notification channel these alerts and the database's own (module.database) share; empty
# leaves them visible in Cloud Monitoring only.

resource "google_monitoring_notification_channel" "email" {
  count = var.alert_email != "" ? 1 : 0

  display_name = "${local.name} email"
  type         = "email"
  labels       = { email_address = var.alert_email }
}

locals {
  notification_channels = var.alert_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}

resource "google_monitoring_alert_policy" "node_cpu" {
  display_name = "${local.name} node CPU"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Allocatable CPU above 80% for 15 minutes"
    condition_threshold {
      filter          = "resource.type = \"k8s_node\" AND resource.label.cluster_name = \"${local.name}\" AND metric.type = \"kubernetes.io/node/cpu/allocatable_utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "900s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.notification_channels
}

resource "google_monitoring_alert_policy" "container_restarts" {
  display_name = "${local.name} container restarts"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "More than 5 container restarts in 15 minutes"
    condition_threshold {
      filter          = "resource.type = \"k8s_container\" AND resource.label.cluster_name = \"${local.name}\" AND metric.type = \"kubernetes.io/container/restart_count\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "0s"
      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.notification_channels
}

resource "google_monitoring_dashboard" "app" {
  dashboard_json = jsonencode({
    displayName = local.name
    mosaicLayout = {
      columns = 24
      tiles = [
        {
          width  = 12
          height = 8
          widget = {
            title = "Cluster"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter      = "resource.type = \"k8s_node\" AND resource.label.cluster_name = \"${local.name}\" AND metric.type = \"kubernetes.io/node/cpu/allocatable_utilization\""
                      aggregation = { alignmentPeriod = "300s", perSeriesAligner = "ALIGN_MEAN" }
                    }
                  }
                },
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter      = "resource.type = \"k8s_container\" AND resource.label.cluster_name = \"${local.name}\" AND metric.type = \"kubernetes.io/container/restart_count\""
                      aggregation = { alignmentPeriod = "900s", perSeriesAligner = "ALIGN_DELTA", crossSeriesReducer = "REDUCE_SUM" }
                    }
                  }
                },
              ]
            }
          }
        },
        {
          xPos   = 12
          width  = 12
          height = 8
          widget = {
            title = "Database"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter      = "resource.type = \"cloudsql_database\" AND resource.label.database_id = \"${var.project_id}:${local.name}\" AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
                      aggregation = { alignmentPeriod = "300s", perSeriesAligner = "ALIGN_MEAN" }
                    }
                  }
                },
              ]
            }
          }
        },
      ]
    }
  })
}
