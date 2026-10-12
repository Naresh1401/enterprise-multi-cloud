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
  name = "${var.cluster_name}-${var.environment}"
  tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "opentofu"
    cluster     = var.cluster_name
  })
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# The cluster's nodes and the database share a virtual network, so the database needs no public endpoint
resource "azurerm_virtual_network" "this" {
  name                = local.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 6, 0)]
}

resource "azurerm_subnet" "database" {
  name                 = "database"
  resource_group_name  = azurerm_resource_group.this.name
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

resource "azurerm_container_registry" "this" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Standard"
  admin_enabled       = false
  tags                = local.tags
}

resource "azurerm_log_analytics_workspace" "logs" {
  name                = var.log_analytics_workspace_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# The API server stays reachable from GitHub-hosted runners, which have no fixed address;
# api_allowed_cidrs narrows who can reach it
#trivy:ignore:AZU-0041
resource "azurerm_kubernetes_cluster" "this" {
  name                      = local.name
  location                  = azurerm_resource_group.this.location
  resource_group_name       = azurerm_resource_group.this.name
  dns_prefix                = local.name
  kubernetes_version        = var.kubernetes_version
  sku_tier                  = var.environment == "prod" ? "Standard" : "Free"
  automatic_upgrade_channel = "stable"
  node_os_upgrade_channel   = "NodeImage"

  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  role_based_access_control_enabled = true

  # Container Insights: pod and node metrics and logs, without a self-managed agent
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
  }

  default_node_pool {
    name                        = "system"
    vm_size                     = var.node_vm_size
    os_sku                      = "AzureLinux"
    vnet_subnet_id              = azurerm_subnet.nodes.id
    auto_scaling_enabled        = true
    min_count                   = var.node_min_count
    max_count                   = var.node_max_count
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = "10%"
    }
  }

  # Nodes scale with the cluster autoscaler on the system pool, not node auto-provisioning
  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type = "SystemAssigned"
  }

  # Azure CNI overlay with Cilium, which also enforces Kubernetes network policies
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.api_allowed_cidrs) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_allowed_cidrs
    }
  }

  tags = local.tags
}

# Nodes join the subnet when the cluster scales, which the cluster's identity does
resource "azurerm_role_assignment" "cluster_network" {
  scope                            = azurerm_subnet.nodes.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_kubernetes_cluster.this.identity[0].principal_id
  skip_service_principal_aad_check = true
}

# Lets the nodes pull images from the registry
resource "azurerm_role_assignment" "acr_pull" {
  scope                            = azurerm_container_registry.this.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}
