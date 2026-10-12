# Alerting policies on Cloud Run's own metrics, and a dashboard that puts them next to the
# database's. alert_email, when set, gets a notification channel every alert here and the
# database's own alerts (module.database) share; empty leaves them visible in Cloud Monitoring
# only.

resource "google_monitoring_notification_channel" "email" {
  count = var.alert_email != "" ? 1 : 0

  display_name = "${var.service_name} email"
  type         = "email"
  labels       = { email_address = var.alert_email }
}

locals {
  notification_channels = var.alert_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}

resource "google_monitoring_alert_policy" "error_rate" {
  display_name = "${var.service_name} 5xx rate"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "More than 10 server errors in 5 minutes"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"${var.service_name}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 10
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.notification_channels
}

resource "google_monitoring_alert_policy" "latency" {
  display_name = "${var.service_name} latency"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "99th percentile request latency above 1s for 15 minutes"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"${var.service_name}\" AND metric.type = \"run.googleapis.com/request_latencies\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1000
      duration        = "900s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_PERCENTILE_99"
      }
    }
  }

  notification_channels = local.notification_channels
}

resource "google_monitoring_dashboard" "app" {
  dashboard_json = jsonencode({
    displayName = var.service_name
    mosaicLayout = {
      columns = 24
      tiles = [
        {
          width  = 12
          height = 8
          widget = {
            title = "Cloud Run"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter      = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"${var.service_name}\" AND metric.type = \"run.googleapis.com/request_count\""
                      aggregation = { alignmentPeriod = "300s", perSeriesAligner = "ALIGN_RATE" }
                    }
                  }
                },
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter      = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"${var.service_name}\" AND metric.type = \"run.googleapis.com/request_latencies\""
                      aggregation = { alignmentPeriod = "300s", perSeriesAligner = "ALIGN_PERCENTILE_99" }
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
                      filter      = "resource.type = \"cloudsql_database\" AND resource.label.database_id = \"${var.project_id}:${var.service_name}\" AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
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
