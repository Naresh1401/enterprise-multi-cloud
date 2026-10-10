# Enterprise Multi-Cloud CI/CD

This repository consolidates the application, delivery pipeline, and cloud
infrastructure from the former `multi-cloud-cicd-blueprint` and
`ai-cicd-private` repositories.

The pipeline is self-contained: it tests and packages the application in this
repository instead of cloning a second application repository at runtime.
The same image is deployed to either Google Cloud Run or Azure Container Apps.

## Delivery flow

```text
Pull request/push
  -> Python tests and syntax checks
  -> OpenTofu format and validation
  -> Docker build and /health smoke test
  -> release metadata artifact (main only)

Manual deployment
  -> OIDC cloud authentication
  -> provision registry/platform infrastructure
  -> build and push image tagged with the commit SHA
  -> apply the complete service configuration
  -> HTTPS /health smoke test
```

## Repository layout

```text
app/                         Flask application
tests/                       Application tests
.github/workflows/ci-cd.yml  Self-contained CI and release metadata
.github/workflows/deploy-gcp.yml
.github/workflows/deploy-azure.yml
infra/gcp/                   Artifact Registry and Cloud Run OpenTofu
infra/azure/                 ACR and Container Apps OpenTofu
docs/                        Architecture and operational runbooks
scripts/                     Local and cloud bootstrap helpers
```

## Local development

Requirements: Python 3.11+ and Docker.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
PYTHONPATH=. pytest -q
python app/main.py
```

The service listens on `http://localhost:8000`; health is available at
`/health`. To test the container:

```bash
docker build -t multi-cloud-app:local .
docker run --rm -p 8000:8000 multi-cloud-app:local
```

## GitHub configuration

Deployment is intentionally manual and protected by GitHub Environments
(`dev` and `prod`). Configure the following **Environment variables**:

### GCP

- `GCP_PROJECT_ID`
- `GCP_REGION`
- `GCP_REPOSITORY`
- `GCP_SERVICE_NAME`
- `GCP_TF_STATE_BUCKET` (an existing, versioned GCS bucket)

Environment secrets:

- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT`

The service account must be allowed to impersonate through the workload
identity provider and have permissions for Artifact Registry, Cloud Run, and
the Terraform state bucket.

### Azure

Environment variables:

- `AZURE_RESOURCE_GROUP`
- `AZURE_LOCATION`
- `AZURE_ACR_NAME` (globally unique, lowercase alphanumeric)
- `AZURE_CONTAINER_APP_ENV`
- `AZURE_CONTAINER_APP_NAME`
- `AZURE_TF_STATE_RESOURCE_GROUP`
- `AZURE_TF_STATE_STORAGE_ACCOUNT`
- `AZURE_TF_STATE_CONTAINER`

Environment secrets:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

The federated identity needs permissions to manage the deployment resource
group, the state storage account, and role assignments. The Container App's
system-assigned identity receives `AcrPull` on the registry through OpenTofu.

The state storage resources are intentionally not created by the deployment
workflow. Create and protect them once using the provider bootstrap scripts,
then grant the deployment identity access. This prevents a failed deployment
from silently creating unmanaged state.

## Deployment

1. Configure the appropriate GitHub Environment variables and secrets.
2. Run **Actions → Deploy to GCP** or **Actions → Deploy to Azure**.
3. Select `dev` or `prod`; production should have required reviewers enabled.
4. Confirm the workflow's HTTPS health check and recorded service URL.

Both workflows use commit-SHA image tags, OIDC authentication, serialized
deployments, remote state, and a two-phase infrastructure apply. The first
phase creates the registry/platform needed to publish the image; the second
phase deploys the now-existing image and service configuration.

## Operational safeguards

- No long-lived cloud service-account key is stored in GitHub.
- No deployment occurs automatically on every push.
- Terraform/OpenTofu state is remote and environment-specific.
- Images are immutable commit-SHA tags rather than `latest`.
- Deployment fails when required configuration is absent.
- Each deployment ends with a live `/health` smoke test.
