# Metric alerts on the server's own platform metrics, so CPU pressure, a nearly full disk or
# too many connections shows up without anyone watching a dashboard. action_group_id, when
# given, is where they notify; empty leaves them visible in Azure Monitor only.

resource "azurerm_monitor_metric_alert" "cpu" {
  name                = "${var.server_name}-cpu"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_postgresql_flexible_server.this.id]
  description         = "${var.server_name} has been above 80% CPU for 15 minutes"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  dynamic "action" {
    for_each = var.action_group_id != "" ? [1] : []
    content {
      action_group_id = var.action_group_id
    }
  }
}

resource "azurerm_monitor_metric_alert" "storage" {
  name                = "${var.server_name}-storage"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_postgresql_flexible_server.this.id]
  description         = "${var.server_name} has less than 10% of its storage free"
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "storage_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 90
  }

  dynamic "action" {
    for_each = var.action_group_id != "" ? [1] : []
    content {
      action_group_id = var.action_group_id
    }
  }
}

resource "azurerm_monitor_metric_alert" "connections" {
  name                = "${var.server_name}-connections"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_postgresql_flexible_server.this.id]
  description         = "${var.server_name} has more than ${var.connection_alarm_threshold} active connections"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "active_connections"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.connection_alarm_threshold
  }

  dynamic "action" {
    for_each = var.action_group_id != "" ? [1] : []
    content {
      action_group_id = var.action_group_id
    }
  }
}
