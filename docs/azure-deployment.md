# Azure deployment guide

This guide sets up everything the **Deploy to Azure** workflow needs. You
create only two things by hand: the storage that holds OpenTofu state, and the
identity GitHub Actions signs in as. OpenTofu creates everything else (resource
group, virtual network, Log Analytics, Container Registry, a PostgreSQL flexible
server with Entra sign-in only, the Container Apps environment, the app's and the
migration job's identities, the migration job and the Container App). Do not
create those resources yourself, or the first apply will fail because they
already exist.

## Prerequisites

- An Azure subscription where you can create resources and role assignments
- Azure CLI 2.60 or later, signed in with `az login`
- GitHub CLI, signed in with `gh auth login`

Set these once in your shell. The storage account name must be globally unique:
3-24 lowercase letters or digits.

```bash
SUBSCRIPTION_ID="<subscription-id>"
LOCATION="eastus"
REPO="Naresh1401/enterprise-multi-cloud"
STATE_RG="rg-multi-cloud-tfstate"
STATE_ACCOUNT="<uniquestatename>"
STATE_CONTAINER="tfstate"

az account set --subscription "$SUBSCRIPTION_ID"
```

## 1. Create the state storage

Versioning and soft delete let you recover a damaged state file. Shared keys are
disabled because OpenTofu signs in with Entra ID (`use_azuread_auth`).

```bash
az group create --name "$STATE_RG" --location "$LOCATION"

az storage account create \
  --name "$STATE_ACCOUNT" \
  --resource-group "$STATE_RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false

az storage account blob-service-properties update \
  --account-name "$STATE_ACCOUNT" \
  --resource-group "$STATE_RG" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 14

az storage container-rm create \
  --storage-account "$STATE_ACCOUNT" \
  --resource-group "$STATE_RG" \
  --name "$STATE_CONTAINER"
```

## 2. Create the deployment identity

The deploy job runs inside a GitHub Environment, so the subject of its OIDC
token is `repo:<owner>/<repo>:environment:<name>`. A federated credential for a
branch will not match. Create one credential per environment:

```bash
APP_ID="$(az ad app create --display-name "github-enterprise-multi-cloud" --query appId -o tsv)"
az ad sp create --id "$APP_ID"

for env in dev prod; do
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"github-${env}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${REPO}:environment:${env}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
done
```

## 3. Grant the identity what the workflow does

- **Contributor** on the subscription, because OpenTofu creates the deployment
  resource group. To scope it more tightly, create the resource group first,
  import it into state, and grant Contributor on that group instead.
- **Role Based Access Control Administrator**, constrained so it can only
  assign or remove `AcrPull` (`7f951dda-4ed3-4680-a7ca-43fe172d538d`) and Network
  Contributor (`4d97b98b-1d4f-4787-a291-c67834d212e7`). OpenTofu uses it to let the
  app's identities pull from the registry and, on AKS, to let the cluster join its
  nodes to their subnet.
- **Storage Blob Data Contributor** on the state container.

Register the resource providers the deployment uses, once per subscription:

```bash
for provider in Microsoft.App Microsoft.ContainerService Microsoft.DBforPostgreSQL Microsoft.Network Microsoft.OperationalInsights; do
  az provider register --namespace "$provider"
done
```

```bash
SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

az role assignment create --assignee "$APP_ID" --role Contributor --scope "$SCOPE"

az role assignment create --assignee "$APP_ID" \
  --role "Role Based Access Control Administrator" \
  --scope "$SCOPE" \
  --condition-version "2.0" \
  --condition "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {7f951dda-4ed3-4680-a7ca-43fe172d538d, 4d97b98b-1d4f-4787-a291-c67834d212e7})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {7f951dda-4ed3-4680-a7ca-43fe172d538d, 4d97b98b-1d4f-4787-a291-c67834d212e7}))"

STATE_ID="$(az storage account show --name "$STATE_ACCOUNT" --resource-group "$STATE_RG" --query id -o tsv)"
az role assignment create --assignee "$APP_ID" \
  --role "Storage Blob Data Contributor" \
  --scope "${STATE_ID}/blobServices/default/containers/${STATE_CONTAINER}"
```

## 4. Configure the GitHub Environments

Repeat for `prod` with its own resource names. The registry name must be
globally unique: 5-50 lowercase letters or digits.

```bash
env=dev
gh api --method PUT "repos/${REPO}/environments/${env}" >/dev/null

gh secret set AZURE_CLIENT_ID       --repo "$REPO" --env "$env" --body "$APP_ID"
gh secret set AZURE_TENANT_ID       --repo "$REPO" --env "$env" --body "$(az account show --query tenantId -o tsv)"
gh secret set AZURE_SUBSCRIPTION_ID --repo "$REPO" --env "$env" --body "$SUBSCRIPTION_ID"

gh variable set AZURE_RESOURCE_GROUP           --repo "$REPO" --env "$env" --body "rg-multi-cloud-${env}"
gh variable set AZURE_LOCATION                 --repo "$REPO" --env "$env" --body "$LOCATION"
gh variable set AZURE_ACR_NAME                 --repo "$REPO" --env "$env" --body "<uniqueacrname${env}>"
gh variable set AZURE_CONTAINER_APP_ENV        --repo "$REPO" --env "$env" --body "cae-multi-cloud-${env}"
gh variable set AZURE_CONTAINER_APP_NAME       --repo "$REPO" --env "$env" --body "multi-cloud-app"
gh variable set AZURE_TF_STATE_RESOURCE_GROUP  --repo "$REPO" --env "$env" --body "$STATE_RG"
gh variable set AZURE_TF_STATE_STORAGE_ACCOUNT --repo "$REPO" --env "$env" --body "$STATE_ACCOUNT"
gh variable set AZURE_TF_STATE_CONTAINER       --repo "$REPO" --env "$env" --body "$STATE_CONTAINER"
```

For `prod`, add required reviewers and restrict deployment branches to `main` in
**Settings > Environments > prod**. The workflow also refuses to deploy `prod`
from any other branch.

## 5. Deploy

```bash
gh workflow run deploy-azure.yml --repo "$REPO" -f environment=dev
gh run watch --repo "$REPO"
```

The workflow:

1. Signs in with OIDC; no client secret exists anywhere.
2. Applies the virtual network, registry, Container Apps environment, the two
   identities and their `AcrPull` grants (phase 1).
3. Builds the image with the commit SHA as its tag and version, and pushes it.
4. Applies the PostgreSQL server, with the migration identity as its Entra
   administrator, and the migration job; then starts the job and waits for it to
   succeed (phase 2). The first run takes 10 minutes or more while the server is
   created.
5. Applies the Container App (phase 3), which signs in to the database as
   `app_user` with its managed identity.
6. Polls `https://<app>/ready` until the new revision reports the commit SHA and a
   working database, then records the URL in the run summary and on the environment.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `AADSTS700213` or `No matching federated identity record` | The credential subject does not match. It must be exactly `repo:<owner>/<repo>:environment:<env>`. |
| `AuthorizationFailed ... roleAssignments/write` | The RBAC Administrator assignment from step 3 is missing or its condition was mistyped. |
| `The registry name is already in use` | ACR names are global. Pick another `AZURE_ACR_NAME`. |
| The first revision fails to pull its image | A new `AcrPull` grant can take a few minutes to propagate. Run the workflow again; it is idempotent. |
| The migration fails | Its output is under the job's **Execution history** in the portal, and in the Log Analytics workspace (`ContainerAppConsoleLogs_CL`). Right after the server is created, its Entra administrator can take a few minutes to become usable; run the workflow again. |
| `ServerNameAlreadyExists` | PostgreSQL server names are global; the server is named `<AZURE_ACR_NAME>-pg`, so pick another registry name. |
| `state blob is already locked` | A previous run was cancelled mid-apply. After confirming no run is active, run `tofu force-unlock <lock-id>` locally with the same backend settings. |

## Tear down

```bash
az group delete --name "rg-multi-cloud-dev" --yes
az storage blob delete --account-name "$STATE_ACCOUNT" --container-name "$STATE_CONTAINER" \
  --name "multi-cloud-app/dev.tfstate" --auth-mode login
```
