output "fqdn" {
  value       = azurerm_postgresql_flexible_server.this.fqdn
  description = "Server hostname, which resolves to its private address inside the virtual network"
}

output "database_name" {
  value       = azurerm_postgresql_flexible_server_database.app.name
  description = "Database the service uses"
}
