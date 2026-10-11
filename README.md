# Enterprise Multi-Cloud

[![CI](https://github.com/Naresh1401/enterprise-multi-cloud/actions/workflows/ci.yml/badge.svg)](https://github.com/Naresh1401/enterprise-multi-cloud/actions/workflows/ci.yml)

A Flask service and the deployment pipelines that ship it to **Google Cloud Run**
or **Azure Container Apps**. Every change passes the quality and security gates
from [github-cicd-workflows](https://github.com/Naresh1401/github-cicd-workflows),
the shared CI that all of my repositories use. Every deployment is a manually dispatched, OIDC-authenticated OpenTofu
run that finishes only when the new commit is the one serving traffic.

```text
Push or pull request (shared workflows from github-cicd-workflows)
  -> ruff, pytest (coverage gate), pip-audit
  -> actionlint, shellcheck, hadolint
  -> OpenTofu fmt and validate (Azure, GCP)
  -> Trivy scan of the Dockerfile and OpenTofu
  -> image build, /health smoke test, non-root check, Trivy image scan
  -> release metadata artifact (main only)

Manual deployment (dev or prod)
  -> OIDC sign-in, no stored cloud keys
  -> phase 1: registry and platform (and on Azure, the pull identity)
  -> build and push the image tagged with the commit SHA
  -> phase 2: the service itself
  -> poll /health until it reports the deployed commit
```

The design and its trade-offs are in [docs/architecture.md](docs/architecture.md).

## Run it locally

Requirements: Python 3.11+, Docker, OpenTofu (for `tofu-check`) and GNU make.

```bash
make check        # lint, tests with coverage, dependency audit
make run          # dev server on http://localhost:8000
make docker-run   # the production image (gunicorn, non-root)
make tofu-check   # OpenTofu fmt and validate for both clouds
make pipeline     # every gate plus an image build and container smoke test
```

If `python3` is older than 3.11, point the targets at a newer interpreter, for
example `make check PYTHON=python3.11`. If port 8000 is taken, run the pipeline
with `HOST_PORT=8080 make pipeline`.

```console
$ curl -s localhost:8000/health
{"service":"enterprise-multi-cloud","status":"healthy","version":"dev"}
```

`/health` reports the commit the image was built from (`APP_VERSION`), which is
how the pipeline confirms a deployment.

## Deploy

1. Set up the cloud side once with [docs/gcp-deployment.md](docs/gcp-deployment.md)
   or [docs/azure-deployment.md](docs/azure-deployment.md). The guides create
   only the OpenTofu state store and the deployment identity; OpenTofu creates
   everything else.
2. Add the variables and secrets below to the `dev` and `prod` GitHub
   Environments. Give `prod` required reviewers.
3. Run **Actions > Deploy to GCP** or **Deploy to Azure** and pick an
   environment. `prod` can only be deployed from `main`.
4. The run summary and the environment link show the live URL and the commit
   it is serving.

### GCP configuration

| Name | Kind | Notes |
| --- | --- | --- |
| `GCP_PROJECT_ID` | variable | |
| `GCP_REGION` | variable | for example `us-central1` |
| `GCP_REPOSITORY` | variable | Artifact Registry repository, one per environment |
| `GCP_SERVICE_NAME` | variable | Cloud Run service name |
| `GCP_TF_STATE_BUCKET` | variable | existing versioned GCS bucket |
| `GCP_RUNTIME_SERVICE_ACCOUNT` | variable | optional; service account Cloud Run runs as |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | secret | full provider resource name |
| `GCP_SERVICE_ACCOUNT` | secret | deployer service account email |

### Azure configuration

| Name | Kind | Notes |
| --- | --- | --- |
| `AZURE_RESOURCE_GROUP` | variable | created by OpenTofu |
| `AZURE_LOCATION` | variable | for example `eastus` |
| `AZURE_ACR_NAME` | variable | globally unique, 5-50 lowercase letters or digits |
| `AZURE_CONTAINER_APP_ENV` | variable | |
| `AZURE_CONTAINER_APP_NAME` | variable | |
| `AZURE_TF_STATE_RESOURCE_GROUP` | variable | existing state resource group |
| `AZURE_TF_STATE_STORAGE_ACCOUNT` | variable | existing state storage account |
| `AZURE_TF_STATE_CONTAINER` | variable | existing state container |
| `AZURE_CLIENT_ID` | secret | Entra app with a federated credential per environment |
| `AZURE_TENANT_ID` | secret | |
| `AZURE_SUBSCRIPTION_ID` | secret | |

## Repository layout

```text
app/                    Flask service
tests/                  pytest suite (100% line and branch coverage of app/)
gunicorn.conf.py        Production server settings (honours PORT)
Dockerfile              Pinned base image, non-root user, healthcheck
infra/gcp/              Artifact Registry and Cloud Run (OpenTofu)
infra/azure/            ACR, Container Apps and the pull identity (OpenTofu)
.github/workflows/      ci.yml (shared gates), deploy-gcp.yml, deploy-azure.yml
.github/dependabot.yml  Weekly updates for Actions, pip and the base image
docs/                   Architecture, deployment runbooks, production checklist
scripts/                Local pipeline and bootstrap checklists
```

## Safeguards

- No long-lived cloud credentials: both clouds trust GitHub's OIDC token.
- Nothing deploys on push; deployments are dispatched and environment-protected.
- Every third-party action is pinned to a full commit SHA.
- The base image is pinned by digest, and Dependabot keeps pins current.
- Images are tagged with the commit SHA, and deployments verify that commit is live.
- OpenTofu state is remote, versioned and separate per environment.
- CI fails on fixable critical or high vulnerabilities and on IaC misconfigurations.

## Background

This repository was `enterprise-multi-cloud-cicd` until its CI gates moved into
[github-cicd-workflows](https://github.com/Naresh1401/github-cicd-workflows), so
every repository can share them. What stays here is the multi-cloud part: the
service, its OpenTofu infrastructure and the deployment pipelines. It started as
a consolidation of `multi-cloud-cicd-blueprint` and `ai-cicd-private`, and builds
its own code instead of cloning a second repository at runtime.
