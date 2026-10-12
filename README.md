# Enterprise Multi-Cloud

[![CI](https://github.com/Naresh1401/enterprise-multi-cloud/actions/workflows/ci.yml/badge.svg)](https://github.com/Naresh1401/enterprise-multi-cloud/actions/workflows/ci.yml)

One Flask service, backed by PostgreSQL, and the pipelines that ship it to **AWS, Google Cloud
and Azure**, on each cloud's serverless container platform or on Kubernetes. Every change passes the quality and
security gates from [github-cicd-workflows](https://github.com/Naresh1401/github-cicd-workflows),
the shared CI that all of my repositories use. Every deployment is a manually dispatched,
OIDC-authenticated OpenTofu run that finishes only when the new commit is the one serving traffic.

| Cloud | Serverless containers | Kubernetes (one Helm chart) | Database |
| --- | --- | --- | --- |
| AWS | ECS Fargate behind an Application Load Balancer | EKS Auto Mode | Amazon RDS for PostgreSQL |
| Google Cloud | Cloud Run | GKE Autopilot | Cloud SQL for PostgreSQL |
| Azure | Container Apps | AKS | Azure Database for PostgreSQL |

```text
Push or pull request (shared workflows from github-cicd-workflows)
  -> ruff, pytest (coverage gate), pip-audit
  -> actionlint, shellcheck, hadolint
  -> OpenTofu fmt and validate for all six targets
  -> Trivy scan of the Dockerfile, OpenTofu and Helm chart
  -> image build, /health smoke test, non-root check, Trivy image scan
  -> Helm lint and schema validation for every cloud's values,
     then a real install on a kind cluster that must report the commit
  -> release metadata artifact (main only)

Manual deployment (dev or prod)
  -> OIDC sign-in, no stored cloud keys
  -> OpenTofu: the registry first, then the platform or cluster and its private PostgreSQL
  -> build and push the image tagged with the commit SHA
  -> migrate the database with a one-off job and its own identity
  -> Cloud Run / Container Apps / ECS service, or helm upgrade on GKE / AKS / EKS
  -> poll /ready until it reports the deployed commit and a working database
```

## Architecture and deployment flows

| Read | For |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | The whole system: the six targets, CI, how a deployment runs, identities, state |
| [docs/aws-architecture.md](docs/aws-architecture.md) | ECS Fargate and EKS: every resource, the deployment flow step by step, commands to check a deployment |
| [docs/gcp-architecture.md](docs/gcp-architecture.md) | Cloud Run and GKE, the same |
| [docs/azure-architecture.md](docs/azure-architecture.md) | Container Apps and AKS, the same |
| [docs/kubernetes-architecture.md](docs/kubernetes-architecture.md) | The Helm chart, its migration hook and the Kubernetes deployment flow |
| [docs/database.md](docs/database.md) | Connecting, signing in without passwords, migrations |

Every architecture page's claims are checked: OpenTofu tests plan each target against mock
providers in CI, `make inventory` lists every resource a target would create without a cloud
account, and `scripts/verify-deployment.sh` checks a live deployment end to end.

## Run it locally

Requirements: Python 3.11+, Docker, OpenTofu (for `tofu-check`), Helm (for `helm-check`) and GNU make.

```bash
make up           # the service with PostgreSQL and its migrations on http://localhost:8000
make check        # lint, tests with coverage against PostgreSQL, dependency audit
make run          # dev server without a database on http://localhost:8000
make docker-run   # the production image (gunicorn, non-root)
make tofu-check   # OpenTofu fmt, validate and tests (plans against mock providers) for every cloud
make inventory    # every resource each target would create, without a cloud account
make helm-check   # lint and render the chart with each cloud's values
make pipeline     # lint, tests and audit, then an image build and container smoke test
make verify URL=https://... VERSION=<commit>   # check a live deployment end to end
```

If `python3` is older than 3.11, point the targets at a newer interpreter, for
example `make check PYTHON=python3.11`. If port 8000 is taken, run the pipeline
with `HOST_PORT=8080 make pipeline`.

```console
$ curl -s localhost:8000/health
{"service":"enterprise-multi-cloud","status":"healthy","version":"dev"}
```

`/health` reports the commit the image was built from (`APP_VERSION`), which is
how the pipeline confirms a deployment. `/ready` also checks the database, and
`/api/items` reads and writes it. How the service connects, signs in without
passwords on each cloud, and migrates its schema is in [docs/database.md](docs/database.md).
To try the Kubernetes chart on a local kind cluster, see
[docs/kubernetes-deployment.md](docs/kubernetes-deployment.md#try-it-locally).

## Deploy

1. Set up the cloud side once: [AWS](docs/aws-deployment.md),
   [Google Cloud](docs/gcp-deployment.md) or [Azure](docs/azure-deployment.md).
   The guides create only the OpenTofu state store and the identity GitHub signs
   in as; OpenTofu creates everything else. Kubernetes needs a few extra
   permissions, listed in [docs/kubernetes-deployment.md](docs/kubernetes-deployment.md).
2. Add the variables and secrets below to the `dev` and `prod` GitHub
   Environments. Give `prod` required reviewers.
3. Run one of the workflows and pick an environment. `prod` can only be deployed from `main`.
   - **Deploy to AWS**: ECS Fargate
   - **Deploy to GCP**: Cloud Run
   - **Deploy to Azure**: Container Apps
   - **Deploy to Kubernetes**: choose `eks`, `gke` or `aks`; the first run creates the cluster
4. The run summary and the environment link show the live URL and the commit it is serving.

### AWS configuration (ECS Fargate and EKS)

| Name | Kind | Notes |
| --- | --- | --- |
| `AWS_REGION` | variable | for example `us-east-1` |
| `AWS_TF_STATE_BUCKET` | variable | existing versioned S3 bucket |
| `AWS_SERVICE_NAME` | variable | ECS only; prefix for the ECS cluster, service and load balancer |
| `AWS_CERTIFICATE_ARN` | variable | ECS only, optional; ACM certificate that turns on HTTPS |
| `AWS_ROLE_ARN` | secret | IAM role GitHub assumes through OIDC |

### GCP configuration (Cloud Run and GKE)

| Name | Kind | Notes |
| --- | --- | --- |
| `GCP_PROJECT_ID` | variable | |
| `GCP_REGION` | variable | for example `us-central1` |
| `GCP_TF_STATE_BUCKET` | variable | existing versioned GCS bucket |
| `GCP_REPOSITORY` | variable | Cloud Run only; Artifact Registry repository, one per environment |
| `GCP_SERVICE_NAME` | variable | Cloud Run only; service name |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | secret | full provider resource name |
| `GCP_SERVICE_ACCOUNT` | secret | deployer service account email |

### Azure configuration (Container Apps and AKS)

| Name | Kind | Notes |
| --- | --- | --- |
| `AZURE_LOCATION` | variable | for example `eastus` |
| `AZURE_TF_STATE_RESOURCE_GROUP` | variable | existing state resource group |
| `AZURE_TF_STATE_STORAGE_ACCOUNT` | variable | existing state storage account |
| `AZURE_TF_STATE_CONTAINER` | variable | existing state container |
| `AZURE_RESOURCE_GROUP` | variable | Container Apps only; created by OpenTofu |
| `AZURE_ACR_NAME` | variable | Container Apps only; globally unique, 5-50 lowercase letters or digits |
| `AZURE_CONTAINER_APP_ENV` | variable | Container Apps only |
| `AZURE_CONTAINER_APP_NAME` | variable | Container Apps only |
| `AKS_RESOURCE_GROUP` | variable | AKS only; created by OpenTofu |
| `AKS_ACR_NAME` | variable | AKS only; globally unique registry for the cluster |
| `AZURE_CLIENT_ID` | secret | Entra app with a federated credential per environment |
| `AZURE_TENANT_ID` | secret | |
| `AZURE_SUBSCRIPTION_ID` | secret | |

## Repository layout

```text
app/                         Flask service, its PostgreSQL connections and the migration job
app/migrations/              Alembic migrations
tests/                       pytest suite against PostgreSQL (100% line and branch coverage of app/),
                             and checks that the docs cover every resource and deploy step
docker-compose.yml           The service, PostgreSQL and the migration job, for local work and CI
gunicorn.conf.py             Production server settings (honours PORT)
Dockerfile                   Pinned base image, non-root user, healthcheck
deploy/helm/multi-cloud-app/ Helm chart, with values for GKE, AKS and EKS
infra/aws/                   VPC, ECR, RDS, ECS Fargate service and load balancer (OpenTofu)
infra/gcp/                   Artifact Registry, VPC, Cloud SQL, the migration job and Cloud Run (OpenTofu)
infra/azure/                 Virtual network, ACR, PostgreSQL, Container Apps and its migration job (OpenTofu)
infra/eks/                   VPC, EKS Auto Mode cluster, ECR and RDS (OpenTofu)
infra/gke/                   VPC, Cloud NAT, GKE Autopilot cluster, Artifact Registry and Cloud SQL (OpenTofu)
infra/aks/                   Virtual network, AKS cluster, ACR and PostgreSQL (OpenTofu)
infra/modules/               The PostgreSQL setup for each cloud, shared by its two targets
deploy/kind/                 A throwaway PostgreSQL for installing the chart on kind
.github/workflows/           ci.yml (shared gates) and one deploy workflow per platform
trivy.yaml                   Misconfiguration scan settings
docs/                        Architecture per cloud, deployment guides, database, production checklist
scripts/                     Deployment checks, resource inventory, local pipeline, bootstrap checklists
```

## Safeguards

- No long-lived cloud credentials: all three clouds trust GitHub's OIDC token.
- No database passwords for the service: it signs in to PostgreSQL with its platform's identity,
  and only the migration job's identity can change the schema. Every database is private and
  verified over TLS.
- `main` only changes through pull requests that pass every CI gate (the required `CI passed` check).
- Nothing deploys on push; deployments are dispatched and environment-protected, and `prod`
  needs an approval and only deploys from `main`.
- Every third-party action is pinned to a full commit SHA.
- The base image is pinned by digest, and Dependabot keeps pins current.
- Images are tagged with the commit SHA, and deployments verify that commit is live.
- OpenTofu state is remote, versioned and separate per environment.
- CI fails on fixable critical or high vulnerabilities and on IaC and Kubernetes misconfigurations.
- On Kubernetes the pods run as non-root with a read-only root filesystem, no capabilities and a
  network policy that admits only the HTTP port.

## Costs

Clusters, databases, NAT gateways and load balancers bill while they exist, even when idle. To remove a
target, run `tofu destroy` in its `infra/` folder with the same backend settings and variables the
workflow uses. GKE clusters have deletion protection on by default; set `deletion_protection =
false` and apply before destroying.

## Background

This repository was `enterprise-multi-cloud-cicd` until its CI gates moved into
[github-cicd-workflows](https://github.com/Naresh1401/github-cicd-workflows), so
every repository can share them. What stays here is the multi-cloud part: the
service, its OpenTofu infrastructure, the Helm chart and the deployment
pipelines. It started as a consolidation of `multi-cloud-cicd-blueprint` and
`ai-cicd-private`, and builds its own code instead of cloning a second
repository at runtime.
