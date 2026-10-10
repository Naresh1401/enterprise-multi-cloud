#!/usr/bin/env bash
set -euo pipefail

echo "Azure bootstrap checklist"
echo "1. Sign in and select the subscription: az login && az account set --subscription <SUBSCRIPTION_ID>"
echo "2. Create a dedicated, locked-down storage account and blob container for Terraform state."
echo "3. Create a federated Entra application/service principal for this GitHub repository and branch."
echo "4. Grant it resource-group deployment permissions and permission to create AcrPull role assignments."
echo "5. Add AZURE_CLIENT_ID, AZURE_TENANT_ID, and AZURE_SUBSCRIPTION_ID as GitHub Environment secrets."
echo "6. Add the Azure resource and state names as GitHub Environment variables."
echo "7. Run the Deploy to Azure workflow and validate the printed Container App URL."
