# Azure deployment guide

This guide explains how to turn the repo into a real Azure deployment using GitHub Actions, Azure Container Registry, and Azure Container Apps.

## Prerequisites

Before running the Azure workflow, you need:

- an Azure subscription
- permission to create resource groups and resources
- Azure CLI installed locally
- Docker available locally for validation
- a GitHub repository with access to Actions secrets

## 1. Log in to Azure locally

```bash
az login
az account set --subscription "<SUBSCRIPTION_ID>"
az account show
```

## 2. Create the Azure resource group and registry

```bash
az group create --name rg-multi-cloud-demo --location eastus
az acr create \
  --resource-group rg-multi-cloud-demo \
  --name multicloudacr123 \
  --sku Basic
```

> Make sure the ACR name is globally unique. If the default name is not available, change it in the Terraform variables and workflow environment values.

## 3. Create the Azure Container Apps environment

```bash
az extension add --name containerapp --upgrade
az containerapp env create \
  --name cae-multi-cloud-demo \
  --resource-group rg-multi-cloud-demo \
  --location eastus
```

## 4. Create the identity for GitHub Actions

You can use either:

- a service principal, or
- OIDC federation with GitHub Actions

### Option A: Service principal

```bash
az ad sp create-for-rbac \
  --name "github-actions-multi-cloud" \
  --role contributor \
  --scopes /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-multi-cloud-demo
```

Keep these values:

- appId
- tenant
- password

### Option B: OIDC federation

This is the preferred setup for GitHub Actions. Use the Azure docs to configure federated credentials between your GitHub repo and Azure, then set the following GitHub secrets:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

## 5. Configure GitHub secrets

Set the repository secrets in GitHub:

```bash
gh secret set AZURE_CLIENT_ID --body "<CLIENT_ID>"
gh secret set AZURE_TENANT_ID --body "<TENANT_ID>"
gh secret set AZURE_SUBSCRIPTION_ID --body "<SUBSCRIPTION_ID>"
```

## 6. Validate the Terraform defaults

The Azure Terraform configuration is in:

- `infra/azure/main.tf`
- `infra/azure/variables.tf`

You can override values in GitHub Actions by updating the environment variables in the workflow.

## 7. Run the workflow

Trigger the Azure deployment workflow in GitHub Actions:

- `.github/workflows/deploy-azure.yml`

This workflow does the following:

1. authenticates to Azure
2. runs Terraform
3. builds the app image
4. pushes it to Azure Container Registry
5. deploys it to Azure Container Apps

## 8. Check the live app URL

After deployment succeeds, run:

```bash
az containerapp show \
  --name multi-cloud-app \
  --resource-group rg-multi-cloud-demo \
  --query properties.configuration.ingress.fqdn \
  -o tsv
```

Then open the URL in a browser and confirm the health endpoint:

```text
https://<fqdn>/health
```

## 9. Production notes

For production, add:

- environment approvals
- separate dev/staging/prod resource groups
- container image retention policies
- Azure Monitor alerts
- resource tagging and cost governance

## Troubleshooting

Common issues:

- ACR name already taken
- missing Azure Container Apps extension
- GitHub Actions identity missing contributor rights
- Terraform plan failing because resources already exist

If a Terraform apply fails, review the plan output and confirm the naming and location values are consistent with your subscription.
