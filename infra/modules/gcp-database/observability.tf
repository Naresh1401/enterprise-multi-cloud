# Alerting policies on Cloud SQL's own metrics, so CPU pressure, a nearly full disk or too
# many connections shows up without anyone watching a dashboard. notification_channels, when
# given, is where they notify; empty leaves them visible in Cloud Monitoring only.

locals {
  database_id = "${var.project_id}:${google_sql_database_instance.this.name}"
}

resource "google_monitoring_alert_policy" "cpu" {
  display_name = "${var.name} database CPU"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "CPU utilization above 80% for 15 minutes"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND resource.label.database_id = \"${local.database_id}\" AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "900s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_monitoring_alert_policy" "disk" {
  display_name = "${var.name} database disk"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Disk utilization above 80% for 15 minutes"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND resource.label.database_id = \"${local.database_id}\" AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "900s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = var.notification_channels
}

resource "google_monitoring_alert_policy" "connections" {
  display_name = "${var.name} database connections"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "More than ${var.connection_alarm_threshold} connections for 15 minutes"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND resource.label.database_id = \"${local.database_id}\" AND metric.type = \"cloudsql.googleapis.com/database/postgresql/num_backends\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.connection_alarm_threshold
      duration        = "900s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = var.notification_channels
}
