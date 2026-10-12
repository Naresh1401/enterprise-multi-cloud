# Plans this folder against a mock Azure provider, so `tofu test` works without a subscription.
# The mocks give IDs the shapes the provider checks.
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-0000000000aa"
      subscription_id = "00000000-0000-0000-0000-0000000000bb"
      object_id       = "00000000-0000-0000-0000-0000000000ee"
    }
  }
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock"
    }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock"
    }
  }
  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/mock"
    }
  }
  mock_resource "azurerm_private_dns_zone" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.Network/privateDnsZones/mock.private.postgres.database.azure.com"
    }
  }
  mock_resource "azurerm_postgresql_flexible_server" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.DBforPostgreSQL/flexibleServers/mock"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mock"
      principal_id = "00000000-0000-0000-0000-0000000000cc"
      client_id    = "00000000-0000-0000-0000-0000000000dd"
    }
  }
  mock_resource "azurerm_container_registry" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.ContainerRegistry/registries/mock"
    }
  }
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/mock"
    }
  }
  mock_resource "azurerm_container_app_environment" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.App/managedEnvironments/mock"
    }
  }
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id              = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.ContainerService/managedClusters/mock"
      oidc_issuer_url = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-0000000000aa/mock/"
    }
  }
  mock_resource "azurerm_container_app" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.App/containerApps/mock"
    }
  }
  mock_resource "azurerm_monitor_action_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.Insights/actionGroups/mock"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.KeyVault/vaults/mock"
    }
  }
  mock_resource "azurerm_key_vault_key" {
    defaults = {
      id = "https://mock.vault.azure.net/keys/database/mockversion"
    }
  }
}

variables {
  environment         = "dev"
  acr_name            = "examplemulticloud"
  resource_group_name = "rg-multi-cloud-dev"
  image_tag           = "0123456789abcdef0123456789abcdef01234567"
}

# Distinct identities, so the assertions can tell the app's from the migration job's
override_resource {
  target = azurerm_user_assigned_identity.app
  values = {
    id           = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/multi-cloud-app-identity"
    principal_id = "00000000-0000-0000-0000-00000000a001"
    client_id    = "00000000-0000-0000-0000-00000000c001"
  }
}
override_resource {
  target = azurerm_user_assigned_identity.migration
  values = {
    id           = "/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/multi-cloud-app-migrate"
    principal_id = "00000000-0000-0000-0000-00000000a002"
    client_id    = "00000000-0000-0000-0000-00000000c002"
  }
}

run "dev" {
  command = plan

  assert {
    condition = (
      azurerm_container_app_environment.cae.infrastructure_subnet_id != null &&
      one(azurerm_container_app_environment.cae.workload_profile).workload_profile_type == "Consumption"
    )
    error_message = "The environment must run in the virtual network on the Consumption profile."
  }
  assert {
    condition = (
      azurerm_subnet.apps.delegation[0].service_delegation[0].name == "Microsoft.App/environments" &&
      azurerm_subnet.database.delegation[0].service_delegation[0].name == "Microsoft.DBforPostgreSQL/flexibleServers" &&
      azurerm_subnet.apps.address_prefixes == tolist(["10.70.0.0/23"]) &&
      azurerm_subnet.database.address_prefixes == tolist(["10.70.8.0/24"])
    )
    error_message = "The apps and the database each need their own delegated subnet."
  }
  assert {
    condition = (
      azurerm_container_app.app.identity[0].identity_ids == toset(["/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/multi-cloud-app-identity"]) &&
      contains([for e in azurerm_container_app.app.template[0].container[0].env : "${e.name}=${e.value}"], "AZURE_CLIENT_ID=00000000-0000-0000-0000-00000000c001")
    )
    error_message = "The app must sign in with its own managed identity."
  }
  assert {
    condition = alltrue([
      for pair in ["DB_AUTH=azure-entra", "DB_USER=app_user", "APP_VERSION=0123456789abcdef0123456789abcdef01234567"] :
      contains([for e in azurerm_container_app.app.template[0].container[0].env : "${e.name}=${e.value}"], pair)
    ])
    error_message = "The app must sign in as app_user with an Entra token and report the commit."
  }
  assert {
    condition = (
      azurerm_container_app.app.template[0].container[0].readiness_probe[0].path == "/ready" &&
      azurerm_container_app.app.template[0].container[0].liveness_probe[0].path == "/health" &&
      azurerm_container_app.app.template[0].container[0].startup_probe[0].path == "/health"
    )
    error_message = "Replicas take traffic once /ready passes; /health keeps them alive."
  }
  assert {
    condition = (
      azurerm_container_app.app.ingress[0].external_enabled &&
      azurerm_container_app.app.ingress[0].target_port == 8000 &&
      azurerm_container_app.app.revision_mode == "Single"
    )
    error_message = "The app is public on port 8000 with one active revision."
  }
  assert {
    condition = (
      azurerm_container_app_job.migrate.name == "multi-cloud-app-migrate" &&
      length(azurerm_container_app_job.migrate.manual_trigger_config) == 1 &&
      azurerm_container_app_job.migrate.template[0].container[0].command == tolist(["python", "-m", "app.migrate"])
    )
    error_message = "The migration job runs python -m app.migrate when the deploy workflow starts it."
  }
  assert {
    condition = (
      azurerm_container_app_job.migrate.identity[0].identity_ids == toset(["/subscriptions/00000000-0000-0000-0000-0000000000bb/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/multi-cloud-app-migrate"]) &&
      alltrue([
        for pair in ["DB_AUTH=azure-entra", "DB_USER=multi-cloud-app-migrate", "AZURE_CLIENT_ID=00000000-0000-0000-0000-00000000c002", "DB_APP_ROLE=app_user", "DB_APP_PRINCIPAL_ID=00000000-0000-0000-0000-00000000a001"] :
        contains([for e in azurerm_container_app_job.migrate.template[0].container[0].env : "${e.name}=${e.value}"], pair)
      ])
    )
    error_message = "The job must sign in as the migration identity and create app_user for the app's identity."
  }
  assert {
    condition = (
      azurerm_role_assignment.acr_pull.role_definition_name == "AcrPull" &&
      azurerm_role_assignment.acr_pull.principal_id == "00000000-0000-0000-0000-00000000a001" &&
      azurerm_role_assignment.acr_pull_migration.role_definition_name == "AcrPull" &&
      azurerm_role_assignment.acr_pull_migration.principal_id == "00000000-0000-0000-0000-00000000a002"
    )
    error_message = "Both identities may only pull images."
  }
  assert {
    condition     = !azurerm_container_registry.acr.admin_enabled
    error_message = "The registry's admin account must stay off; pulls use managed identities."
  }
  assert {
    condition     = output.migration_job_name == "multi-cloud-app-migrate"
    error_message = "The deploy workflow finds the job by this output."
  }
  assert {
    condition = (
      azurerm_monitor_metric_alert.restarts.criteria[0].metric_name == "RestartCount" &&
      azurerm_monitor_metric_alert.error_rate.criteria[0].metric_name == "Requests" &&
      contains(one(azurerm_monitor_metric_alert.error_rate.criteria[0].dimension).values, "5XX") &&
      length(azurerm_monitor_action_group.alerts) == 0 &&
      length(azurerm_monitor_metric_alert.restarts.action) == 0
    )
    error_message = "The app must have its own restart and 5xx alerts, unnotified without alert_email."
  }
}

run "alerts" {
  command = plan

  variables {
    alert_email = "ops@example.com"
  }

  assert {
    condition = (
      azurerm_monitor_action_group.alerts[0].email_receiver[0].email_address == "ops@example.com" &&
      one(azurerm_monitor_metric_alert.restarts.action).action_group_id == azurerm_monitor_action_group.alerts[0].id
    )
    error_message = "alert_email must notify the app's alerts through its own action group."
  }
}

run "customer_managed_key" {
  command = plan

  variables {
    enable_customer_managed_key = true
    key_vault_name              = "examplemulticloudkv"
  }

  assert {
    condition = (
      azurerm_key_vault.database[0].rbac_authorization_enabled == false &&
      azurerm_key_vault.database[0].purge_protection_enabled &&
      length(azurerm_key_vault.database[0].access_policy) == 2
    )
    error_message = "The vault must use access policies (not RBAC), with purge protection, and grant both the deployer and the server's identity."
  }
  assert {
    condition     = length(azurerm_key_vault_key.database[0].key_opts) == 2 && contains(azurerm_key_vault_key.database[0].key_opts, "wrapKey") && contains(azurerm_key_vault_key.database[0].key_opts, "unwrapKey")
    error_message = "The key must only wrap and unwrap, nothing else."
  }
}

run "customer_managed_key_without_name" {
  command = plan

  variables {
    enable_customer_managed_key = true
  }

  expect_failures = [azurerm_key_vault.database]
}
