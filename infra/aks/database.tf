# PostgreSQL for the cluster. The pods sign in with Microsoft Entra Workload ID: each Kubernetes
# service account is federated with its own managed identity. The migration job's identity
# administers the server; the service's identity only gets the role the migration job creates.
data "azurerm_client_config" "current" {}

resource "azurerm_user_assigned_identity" "app" {
  name                = "${local.name}-app"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "migration" {
  name                = "${local.name}-migrate"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "workload" {
  for_each = {
    (var.release_name)            = azurerm_user_assigned_identity.app.id
    "${var.release_name}-migrate" = azurerm_user_assigned_identity.migration.id
  }

  name                      = "${var.kubernetes_namespace}-${each.key}"
  user_assigned_identity_id = each.value
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.kubernetes_namespace}:${each.key}"
  audience                  = ["api://AzureADTokenExchange"]
}

module "database" {
  source = "../modules/azure-database"

  # The registry name is already globally unique, so the server's name is too
  server_name          = "${var.acr_name}-pg"
  environment          = var.environment
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  virtual_network_id   = azurerm_virtual_network.this.id
  delegated_subnet_id  = azurerm_subnet.database.id
  tenant_id            = data.azurerm_client_config.current.tenant_id
  admin_principal_id   = azurerm_user_assigned_identity.migration.principal_id
  admin_principal_name = azurerm_user_assigned_identity.migration.name
  sku_name             = var.database_sku
  tags                 = local.tags
  action_group_id      = local.action_group_id
}
