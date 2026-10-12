# The control plane's own logs, alongside Container Insights' node and pod metrics (both
# already send to azurerm_log_analytics_workspace.logs), and alerts on node CPU and memory so
# pressure shows up without anyone watching the workspace. alert_email, when set, is where
# they notify; the same action group covers the database's alerts (module.database).

resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "${local.name}-control-plane"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id

  enabled_log {
    category = "kube-apiserver"
  }
  enabled_log {
    category = "kube-audit"
  }
  enabled_log {
    category = "kube-controller-manager"
  }
  enabled_log {
    category = "kube-scheduler"
  }
  enabled_log {
    category = "cluster-autoscaler"
  }
  enabled_log {
    category = "guard"
  }
}

resource "azurerm_monitor_action_group" "alerts" {
  count = var.alert_email != "" ? 1 : 0

  name                = "${local.name}-alerts"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = "alerts"
  tags                = local.tags

  email_receiver {
    name          = "email"
    email_address = var.alert_email
  }
}

locals {
  action_group_id = var.alert_email != "" ? azurerm_monitor_action_group.alerts[0].id : ""
}

resource "azurerm_monitor_metric_alert" "node_cpu" {
  name                = "${local.name}-node-cpu"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_kubernetes_cluster.this.id]
  description         = "${local.name}'s nodes have been above 80% CPU for 15 minutes"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_cpu_usage_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  dynamic "action" {
    for_each = var.alert_email != "" ? [1] : []
    content {
      action_group_id = local.action_group_id
    }
  }
}

resource "azurerm_monitor_metric_alert" "node_memory" {
  name                = "${local.name}-node-memory"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_kubernetes_cluster.this.id]
  description         = "${local.name}'s nodes have been above 80% memory for 15 minutes"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_memory_working_set_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  dynamic "action" {
    for_each = var.alert_email != "" ? [1] : []
    content {
      action_group_id = local.action_group_id
    }
  }
}
