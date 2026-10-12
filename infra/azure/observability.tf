# An action group and metric alerts on the Container App's own platform metrics, so repeated
# restarts or a rising server-error rate show up without anyone watching the Log Analytics
# workspace. alert_email, when set, is where they notify; the same action group covers the
# database's alerts (module.database). Empty leaves them visible in Azure Monitor only.

resource "azurerm_monitor_action_group" "alerts" {
  count = var.alert_email != "" ? 1 : 0

  name                = "${var.container_app_name}-alerts"
  resource_group_name = azurerm_resource_group.rg.name
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

resource "azurerm_monitor_metric_alert" "restarts" {
  name                = "${var.container_app_name}-restarts"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_container_app.app.id]
  description         = "${var.container_app_name} has restarted more than 5 times in 15 minutes"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "RestartCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 5
  }

  dynamic "action" {
    for_each = var.alert_email != "" ? [1] : []
    content {
      action_group_id = local.action_group_id
    }
  }
}

resource "azurerm_monitor_metric_alert" "error_rate" {
  name                = "${var.container_app_name}-5xx"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_container_app.app.id]
  description         = "${var.container_app_name} has returned more than 10 server errors in 5 minutes"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 10

    dimension {
      name     = "statusCodeCategory"
      operator = "Include"
      values   = ["5XX"]
    }
  }

  dynamic "action" {
    for_each = var.alert_email != "" ? [1] : []
    content {
      action_group_id = local.action_group_id
    }
  }
}
