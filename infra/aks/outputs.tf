output "cluster_name" {
  value       = azurerm_kubernetes_cluster.this.name
  description = "AKS cluster name, for az aks get-credentials"
}

output "resource_group" {
  value       = azurerm_resource_group.this.name
  description = "Resource group of the cluster"
}

output "registry" {
  value       = azurerm_container_registry.this.login_server
  description = "Registry login server the deploy workflow pushes to"
}

output "database_host" {
  value       = module.database.fqdn
  description = "PostgreSQL flexible server hostname"
}

output "helm_values" {
  description = "Chart values that connect the release to this cluster's database"
  value = yamlencode({
    serviceAccount = {
      annotations = { "azure.workload.identity/client-id" = azurerm_user_assigned_identity.app.client_id }
    }
    database = {
      enabled = true
      host    = module.database.fqdn
      name    = module.database.database_name
      user    = "app_user"
      migrations = {
        user           = azurerm_user_assigned_identity.migration.name
        appPrincipalId = azurerm_user_assigned_identity.app.principal_id
        serviceAccount = {
          annotations = { "azure.workload.identity/client-id" = azurerm_user_assigned_identity.migration.client_id }
        }
      }
      egress = {
        to = [for prefix in azurerm_subnet.database.address_prefixes : { ipBlock = { cidr = prefix } }]
      }
    }
  })
}
