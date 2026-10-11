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
