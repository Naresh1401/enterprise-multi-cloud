# Checks the flexible server settings the architecture relies on, planned against a mock
# Azure provider (no subscription needed): `tofu init -backend=false && tofu test`
mock_provider "azurerm" {
  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.Network/privateDnsZones/examplemulticloud-pg.private.postgres.database.azure.com"
    }
  }
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.DBforPostgreSQL/flexibleServers/examplemulticloud-pg"
    }
  }
}

variables {
  server_name          = "examplemulticloud-pg"
  environment          = "dev"
  resource_group_name  = "rg-mock"
  location             = "eastus"
  virtual_network_id   = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock"
  delegated_subnet_id  = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/database"
  tenant_id            = "00000000-0000-0000-0000-0000000000aa"
  admin_principal_id   = "00000000-0000-0000-0000-0000000000cc"
  admin_principal_name = "multi-cloud-dev-migrate"
}

run "dev" {
  command = plan

  assert {
    condition = (
      !azurerm_postgresql_flexible_server.this.public_network_access_enabled &&
      azurerm_postgresql_flexible_server.this.delegated_subnet_id == var.delegated_subnet_id
    )
    error_message = "The server must live in the delegated subnet with no public endpoint."
  }
  assert {
    condition = (
      azurerm_postgresql_flexible_server.this.authentication[0].active_directory_auth_enabled &&
      !azurerm_postgresql_flexible_server.this.authentication[0].password_auth_enabled
    )
    error_message = "Only Microsoft Entra sign-in may be on; password sign-in must be off."
  }
  assert {
    condition     = azurerm_postgresql_flexible_server.this.version == "17"
    error_message = "The server must run PostgreSQL 17, like the other clouds."
  }
  assert {
    condition     = endswith(azurerm_private_dns_zone.this.name, ".postgres.database.azure.com") && !azurerm_private_dns_zone_virtual_network_link.this.registration_enabled
    error_message = "The server's name must resolve through a private DNS zone linked to the network."
  }
  assert {
    condition = (
      azurerm_postgresql_flexible_server.this.backup_retention_days == 7 &&
      length(azurerm_postgresql_flexible_server.this.high_availability) == 0
    )
    error_message = "dev keeps 7 days of backups without high availability."
  }
  assert {
    condition = (
      azurerm_postgresql_flexible_server_active_directory_administrator.migration.principal_type == "ServicePrincipal" &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migration.object_id == var.admin_principal_id &&
      azurerm_postgresql_flexible_server_active_directory_administrator.migration.principal_name == var.admin_principal_name
    )
    error_message = "The migration identity must be the server's Entra administrator."
  }
  assert {
    condition = alltrue([
      for name in ["require_secure_transport", "log_connections", "log_disconnections", "log_checkpoints", "connection_throttle.enable"] :
      azurerm_postgresql_flexible_server_configuration.settings[name].value == "on"
    ])
    error_message = "TLS must be required, and connections, disconnections and checkpoints logged."
  }
}

run "prod" {
  command = plan

  variables {
    environment = "prod"
    sku_name    = "GP_Standard_D2ds_v5"
  }

  assert {
    condition = (
      azurerm_postgresql_flexible_server.this.backup_retention_days == 14 &&
      azurerm_postgresql_flexible_server.this.high_availability[0].mode == "ZoneRedundant"
    )
    error_message = "prod must be zone-redundant with 14 days of backups."
  }
}
