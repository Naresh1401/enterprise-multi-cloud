# Azure Database for PostgreSQL flexible server for one deployment target (Container Apps or
# AKS): inside the virtual network with no public endpoint, and Microsoft Entra sign-in only.
# Password authentication is off, so no database password exists.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.0"
    }
  }
}

locals {
  prod = var.environment == "prod"
}

# The server's name resolves to its private address only inside the virtual network
resource "azurerm_private_dns_zone" "this" {
  name                = "${var.server_name}.private.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  name                 = var.server_name
  private_dns_zone_id  = azurerm_private_dns_zone.this.id
  virtual_network_id   = var.virtual_network_id
  registration_enabled = false
  tags                 = var.tags
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.server_name
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.postgresql_version
  sku_name            = var.sku_name
  storage_mb          = var.storage_mb
  auto_grow_enabled   = true

  # VNet integration: the server gets an address in the delegated subnet and no public endpoint
  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = azurerm_private_dns_zone.this.id
  public_network_access_enabled = false

  # Azure's own key by default; a customer-managed one, wrapped by the given identity, only if
  # given one. Both can only be set when the server is created, not added to one that exists.
  dynamic "identity" {
    for_each = var.key_vault_key_id != "" ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [var.key_vault_user_assigned_identity_id]
    }
  }

  dynamic "customer_managed_key" {
    for_each = var.key_vault_key_id != "" ? [1] : []
    content {
      key_vault_key_id                  = var.key_vault_key_id
      primary_user_assigned_identity_id = var.key_vault_user_assigned_identity_id
    }
  }

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = var.tenant_id
  }

  backup_retention_days        = local.prod ? 14 : 7
  geo_redundant_backup_enabled = false

  dynamic "high_availability" {
    # Burstable servers can't be zone-redundant; production uses General Purpose
    for_each = local.prod ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  maintenance_window {
    day_of_week  = 0
    start_hour   = 4
    start_minute = 0
  }

  tags = var.tags

  lifecycle {
    # Azure picks the zones when none are given; don't move the server afterwards
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.this]
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# The migration job's managed identity administers the server. It signs in with an Entra
# token, creates the service's role and owns the tables.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "migration" {
  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  object_id           = var.admin_principal_id
  principal_name      = var.admin_principal_name
  principal_type      = "ServicePrincipal"
}

resource "azurerm_postgresql_flexible_server_configuration" "settings" {
  # TLS only (already the default), and connections, disconnections and checkpoints in the logs
  for_each = {
    "require_secure_transport"   = "on"
    "log_connections"            = "on"
    "log_disconnections"         = "on"
    "log_checkpoints"            = "on"
    "connection_throttle.enable" = "on"
  }

  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = each.value
}
