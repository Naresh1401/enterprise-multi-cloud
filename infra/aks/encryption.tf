# A Key Vault, a key and the identity the database wraps it with. Off by default
# (enable_customer_managed_key): Azure's own key encrypts the server already.
#
# Azure requires the vault to have soft delete (always on) and purge protection before it will
# accept a customer-managed key, so destroying this environment leaves the vault soft-deleted
# for soft_delete_retention_days: `tofu apply` again with the same key_vault_name fails until
# that window passes, or until someone with Key Vault purge rights removes it by hand.
#
# Enabling this after the server already exists forces OpenTofu to replace it: the server can't
# switch to a customer-managed key in place. Set it before the first apply, not after.
resource "azurerm_user_assigned_identity" "database_key" {
  count = var.enable_customer_managed_key ? 1 : 0

  name                = "${local.name}-database-key"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_key_vault" "database" {
  count = var.enable_customer_managed_key ? 1 : 0

  name                       = var.key_vault_name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = false
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
  tags                       = local.tags

  # The identity running OpenTofu creates and manages the key
  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions = ["Create", "Get", "List", "WrapKey", "UnwrapKey", "Delete", "Purge"]
  }

  # The server's identity only wraps and unwraps with it
  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = azurerm_user_assigned_identity.database_key[0].principal_id

    key_permissions = ["Get", "WrapKey", "UnwrapKey"]
  }

  lifecycle {
    precondition {
      condition     = var.key_vault_name != ""
      error_message = "key_vault_name must be set (globally unique, 3-24 characters) when enable_customer_managed_key is true."
    }
  }
}

resource "azurerm_key_vault_key" "database" {
  count = var.enable_customer_managed_key ? 1 : 0

  name         = "database"
  key_vault_id = azurerm_key_vault.database[0].id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["wrapKey", "unwrapKey"]
}

locals {
  key_vault_key_id                    = var.enable_customer_managed_key ? azurerm_key_vault_key.database[0].id : ""
  key_vault_user_assigned_identity_id = var.enable_customer_managed_key ? azurerm_user_assigned_identity.database_key[0].id : ""
}
