terraform {
  required_version = ">= 1.6.0"

  backend "azurerm" {
    use_azuread_auth = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "opentofu"
    service     = var.container_app_name
  })
  image = "${azurerm_container_registry.acr.login_server}/${var.image_name}:${var.image_tag}"
  # Container Apps job names are up to 32 characters
  migrate_job_name = "${trimsuffix(substr(var.container_app_name, 0, 24), "-")}-migrate"
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "logs" {
  name                = var.log_analytics_workspace_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# The Container Apps environment and the database share a virtual network, so the database
# needs no public endpoint
resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.container_app_name}-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "apps" {
  name                 = "container-apps"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 7, 0)]

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "database" {
  name                 = "database"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 8)]

  delegation {
    name = "postgresql"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

resource "azurerm_container_app_environment" "cae" {
  name                       = var.container_app_environment_name
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
  infrastructure_subnet_id   = azurerm_subnet.apps.id
  tags                       = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# The app pulls from ACR with a user-assigned identity that exists, and holds
# AcrPull, before the first revision is created. A system-assigned identity
# only exists once the app does, so its first revision could not pull the image.
resource "azurerm_user_assigned_identity" "app" {
  name                = "${var.container_app_name}-identity"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  principal_type       = "ServicePrincipal"
}

# The migration job's identity: it administers the database and pulls the same image
resource "azurerm_user_assigned_identity" "migration" {
  name                = "${var.container_app_name}-migrate"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull_migration" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.migration.principal_id
  principal_type       = "ServicePrincipal"
}

# PostgreSQL with Entra sign-in only. The service signs in as app_user with its managed
# identity's token; the migration identity is the server's Entra administrator.
module "database" {
  source = "../modules/azure-database"

  # The registry name is already globally unique, so the server's name is too
  server_name          = "${var.acr_name}-pg"
  environment          = var.environment
  resource_group_name  = azurerm_resource_group.rg.name
  location             = azurerm_resource_group.rg.location
  virtual_network_id   = azurerm_virtual_network.this.id
  delegated_subnet_id  = azurerm_subnet.database.id
  tenant_id            = data.azurerm_client_config.current.tenant_id
  admin_principal_id   = azurerm_user_assigned_identity.migration.principal_id
  admin_principal_name = azurerm_user_assigned_identity.migration.name
  sku_name             = var.database_sku
  tags                 = local.tags
  action_group_id      = local.action_group_id
}

# Runs the migrations; the deploy workflow starts it and waits for it before it updates the app
resource "azurerm_container_app_job" "migrate" {
  name                         = local.migrate_job_name
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 600
  replica_retry_limit          = 1
  tags                         = local.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.migration.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.migration.id
  }

  template {
    container {
      name    = "migrate"
      image   = local.image
      command = ["python", "-m", "app.migrate"]
      cpu     = 0.5
      memory  = "1Gi"

      dynamic "env" {
        for_each = {
          APP_ENV             = var.environment
          DB_AUTH             = "azure-entra"
          DB_HOST             = module.database.fqdn
          DB_NAME             = module.database.database_name
          DB_USER             = azurerm_user_assigned_identity.migration.name
          AZURE_CLIENT_ID     = azurerm_user_assigned_identity.migration.client_id
          DB_APP_AUTH         = "azure-entra"
          DB_APP_ROLE         = "app_user"
          DB_APP_PRINCIPAL_ID = azurerm_user_assigned_identity.app.principal_id
        }
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  # Targeting the job applies everything a migration needs, the Entra administrator included
  depends_on = [azurerm_role_assignment.acr_pull_migration, module.database]
}

resource "azurerm_container_app" "app" {
  name                         = var.container_app_name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    target_port      = 8000
    external_enabled = true
    transport        = "auto"
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "multi-cloud-app"
      image  = local.image
      cpu    = 0.5
      memory = "1.0Gi"

      dynamic "env" {
        for_each = {
          APP_ENV     = var.environment
          APP_VERSION = var.image_tag
          DB_AUTH     = "azure-entra"
          DB_HOST     = module.database.fqdn
          DB_NAME     = module.database.database_name
          DB_USER     = "app_user"
          # Which of the app's identities signs in to the database
          AZURE_CLIENT_ID = azurerm_user_assigned_identity.app.client_id
        }
        content {
          name  = env.key
          value = env.value
        }
      }

      startup_probe {
        transport               = "HTTP"
        port                    = 8000
        path                    = "/health"
        failure_count_threshold = 10
        interval_seconds        = 3
      }

      # Traffic only reaches replicas that can query the database
      readiness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/ready"
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/health"
      }
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull, azurerm_container_app_job.migrate]
}

output "container_app_fqdn" {
  value       = azurerm_container_app.app.ingress[0].fqdn
  description = "Public Azure Container App hostname"
}

output "container_app_url" {
  value       = "https://${azurerm_container_app.app.ingress[0].fqdn}"
  description = "Public Azure Container App URL"
}

output "migration_job_name" {
  value       = azurerm_container_app_job.migrate.name
  description = "Container Apps job that runs the migrations"
}

output "database_host" {
  value       = module.database.fqdn
  description = "PostgreSQL flexible server hostname"
}
