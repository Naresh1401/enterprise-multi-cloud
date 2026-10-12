# Container Insights, so pod and node metrics reach CloudWatch at all (EKS, unlike ECS,
# publishes nothing on its own); alarms on those metrics; and a dashboard next to the
# database's. alert_email (passed to module.database) is the one place that turns on
# notifications.

resource "aws_iam_role" "observability" {
  name               = "${local.name}-observability"
  description        = "The CloudWatch agent the amazon-cloudwatch-observability add-on installs"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "observability" {
  role       = aws_iam_role.observability.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_pod_identity_association" "observability" {
  cluster_name    = module.eks.cluster_name
  namespace       = "amazon-cloudwatch"
  service_account = "cloudwatch-agent"
  role_arn        = aws_iam_role.observability.arn
}

resource "aws_eks_addon" "observability" {
  cluster_name = module.eks.cluster_name
  addon_name   = "amazon-cloudwatch-observability"
  depends_on   = [aws_eks_pod_identity_association.observability]
}

locals {
  alarm_actions = module.database.alarm_topic_arn != null ? [module.database.alarm_topic_arn] : []
}

resource "aws_cloudwatch_metric_alarm" "node_cpu" {
  alarm_name          = "${local.name}-node-cpu"
  alarm_description   = "${local.name}'s nodes have been above 80% CPU for 15 minutes"
  namespace           = "ContainerInsights"
  metric_name         = "node_cpu_utilization"
  dimensions          = { ClusterName = module.eks.cluster_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  depends_on = [aws_eks_addon.observability]
}

resource "aws_cloudwatch_metric_alarm" "pod_restarts" {
  alarm_name          = "${local.name}-pod-restarts"
  alarm_description   = "${local.name}'s pods have restarted more than 5 times in 15 minutes"
  namespace           = "ContainerInsights"
  metric_name         = "pod_number_of_container_restarts"
  dimensions          = { ClusterName = module.eks.cluster_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  depends_on = [aws_eks_addon.observability]
}

resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Cluster"
          region = var.region
          metrics = [
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", module.eks.cluster_name],
            ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", module.eks.cluster_name, { stat = "Sum" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Database"
          region = var.region
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.name],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", local.name],
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", local.name, { yAxis = "right" }],
          ]
        }
      },
    ]
  })
}
