# Alarms on the metrics RDS already publishes to CloudWatch, so a full database, a runaway
# connection count or sustained CPU pressure shows up without anyone watching a dashboard.
# alert_email, when set, gets an SNS subscription; empty leaves the alarms visible in the
# console with no one notified.

resource "aws_sns_topic" "alerts" {
  count = var.alert_email != "" ? 1 : 0

  name              = "${var.name}-database-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alarm_actions = var.alert_email != "" ? [aws_sns_topic.alerts[0].arn] : []
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "${var.name}-database-cpu"
  alarm_description   = "${var.name}'s database has been above ${var.cpu_alarm_threshold}% CPU for 15 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.cpu_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# Free space below 10% of what's allocated now; max_allocated_storage lets it grow before
# this fires, so it means the autoscaling ceiling itself is close
resource "aws_cloudwatch_metric_alarm" "storage" {
  alarm_name          = "${var.name}-database-storage"
  alarm_description   = "${var.name}'s database has less than 10% of its allocated storage free"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.allocated_storage * 1024 * 1024 * 1024 * 0.1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "connections" {
  alarm_name          = "${var.name}-database-connections"
  alarm_description   = "${var.name}'s database has more than ${var.connection_alarm_threshold} open connections"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.connection_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# RDS has no CloudWatch metric for a Multi-AZ failover; it's an event instead. Only prod is
# Multi-AZ, and only alert_email gives RDS somewhere to send the notification.
resource "aws_db_event_subscription" "failover" {
  count = local.prod && var.alert_email != "" ? 1 : 0

  name             = "${var.name}-database-failover"
  sns_topic        = aws_sns_topic.alerts[0].arn
  source_type      = "db-instance"
  source_ids       = [aws_db_instance.this.id]
  event_categories = ["failover"]
}
