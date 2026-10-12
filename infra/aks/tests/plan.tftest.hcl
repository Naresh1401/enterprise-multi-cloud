# Plans this folder against a mock Azure provider, so `tofu test` works without a subscription.
# The mocks give IDs the shapes the provider checks.
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-0000000000aa"
      subscription_id = "00000000-0000-0000-0000-0000000000bb"
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
}

variables {
  environment         = "dev"
  acr_name            = "examplemulticloud"
  resource_group_name = "rg-multi-cloud-aks-dev"
}

run "dev" {
  command = plan

  # Everything except the nodes' AcrPull assignment, which reads the kubelet identity: a block
  # AKS fills in after creation, and a mock can only fill blocks the configuration sets
  plan_options {
    target = [
      azurerm_container_registry.this,
      azurerm_role_assignment.cluster_network,
      azurerm_federated_identity_credential.workload,
      module.database,
    ]
  }

  assert {
    condition = (
      azurerm_kubernetes_cluster.this.oidc_issuer_enabled &&
      azurerm_kubernetes_cluster.this.workload_identity_enabled &&
      azurerm_kubernetes_cluster.this.role_based_access_control_enabled
    )
    error_message = "The cluster must issue OIDC tokens for Microsoft Entra Workload ID, with RBAC on."
  }
  assert {
    condition = (
      azurerm_kubernetes_cluster.this.network_profile[0].network_plugin == "azure" &&
      azurerm_kubernetes_cluster.this.network_profile[0].network_plugin_mode == "overlay" &&
      azurerm_kubernetes_cluster.this.network_profile[0].network_policy == "cilium" &&
      azurerm_kubernetes_cluster.this.default_node_pool[0].vnet_subnet_id != null
    )
    error_message = "Nodes must join the cluster's subnet, with Azure CNI overlay and Cilium network policies."
  }
  assert {
    condition = (
      azurerm_kubernetes_cluster.this.sku_tier == "Free" &&
      azurerm_kubernetes_cluster.this.automatic_upgrade_channel == "stable" &&
      azurerm_kubernetes_cluster.this.node_os_upgrade_channel == "NodeImage" &&
      azurerm_kubernetes_cluster.this.default_node_pool[0].os_sku == "AzureLinux"
    )
    error_message = "dev runs the Free tier, upgraded automatically on the stable channel."
  }
  assert {
    condition = (
      azurerm_federated_identity_credential.workload["multi-cloud-app"].subject == "system:serviceaccount:multi-cloud-app:multi-cloud-app" &&
      azurerm_federated_identity_credential.workload["multi-cloud-app-migrate"].subject == "system:serviceaccount:multi-cloud-app:multi-cloud-app-migrate" &&
      alltrue([for credential in azurerm_federated_identity_credential.workload : credential.audience == tolist(["api://AzureADTokenExchange"])])
    )
    error_message = "Each Kubernetes service account must be federated with its own managed identity."
  }
  assert {
    condition     = azurerm_role_assignment.cluster_network.role_definition_name == "Network Contributor"
    error_message = "The cluster needs Network Contributor on its node subnet."
  }
  assert {
    condition = (
      azurerm_subnet.nodes.address_prefixes == tolist(["10.60.0.0/22"]) &&
      azurerm_subnet.database.address_prefixes == tolist(["10.60.8.0/24"]) &&
      azurerm_subnet.database.delegation[0].service_delegation[0].name == "Microsoft.DBforPostgreSQL/flexibleServers"
    )
    error_message = "Nodes and the database each need their own subnet."
  }
  assert {
    condition     = !azurerm_container_registry.this.admin_enabled
    error_message = "The registry's admin account must stay off."
  }
  assert {
    condition = (
      yamldecode(output.helm_values).database.enabled &&
      yamldecode(output.helm_values).database.user == "app_user" &&
      yamldecode(output.helm_values).database.migrations.user == "multi-cloud-dev-migrate" &&
      can(yamldecode(output.helm_values).serviceAccount.annotations["azure.workload.identity/client-id"]) &&
      can(yamldecode(output.helm_values).database.migrations.serviceAccount.annotations["azure.workload.identity/client-id"]) &&
      [for peer in yamldecode(output.helm_values).database.egress.to : peer.ipBlock.cidr] == ["10.60.8.0/24"]
    )
    error_message = "The chart values must carry both identities, the migration user and the database subnet."
  }
}

run "prod" {
  command = plan

  variables {
    environment = "prod"
  }

  plan_options {
    target = [azurerm_kubernetes_cluster.this]
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.sku_tier == "Standard"
    error_message = "prod runs the Standard tier, which has an uptime SLA."
  }
}
