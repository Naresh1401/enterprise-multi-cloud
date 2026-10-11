#!/usr/bin/env bash
# Prints the one-time Azure setup. docs/azure-deployment.md has the exact commands.
set -euo pipefail

cat <<'STEPS'
Azure bootstrap (one time, see docs/azure-deployment.md)

1. az login && az account set --subscription <SUBSCRIPTION_ID>
2. Create the OpenTofu state storage: a resource group, a StorageV2 account with
   shared keys and public blob access disabled, versioning on, and a container.
3. Create an Entra app and service principal for GitHub Actions, with one
   federated credential per GitHub Environment. The subject must be:
     repo:<owner>/<repo>:environment:dev
     repo:<owner>/<repo>:environment:prod
4. Grant it Contributor, RBAC Administrator limited to AcrPull, and
   Storage Blob Data Contributor on the state container.
5. Add AZURE_CLIENT_ID, AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID as secrets,
   and the resource and state names as variables, in each GitHub Environment.
6. Run "Deploy to Azure" and confirm the run summary shows the commit SHA.

Do not create the resource group, registry or Container Apps environment by
hand; OpenTofu creates them.
STEPS
