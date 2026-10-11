# GCP deployment guide

This guide sets up everything the **Deploy to GCP** workflow needs. You create
the state bucket, the deployer service account and Workload Identity
Federation by hand. OpenTofu creates the Artifact Registry repository and the
Cloud Run service. Do not create those yourself, or the first apply will fail
because they already exist.

No service account key is ever created; GitHub Actions exchanges its OIDC token
for short-lived Google credentials.

## Prerequisites

- A GCP project with billing enabled
- Google Cloud CLI, signed in with `gcloud auth login`
- GitHub CLI, signed in with `gh auth login`

```bash
PROJECT_ID="<project-id>"
REGION="us-central1"
REPO="Naresh1401/enterprise-multi-cloud-cicd"
STATE_BUCKET="${PROJECT_ID}-tfstate"
DEPLOYER="github-deployer"
POOL="github"
PROVIDER="github-actions"

gcloud config set project "$PROJECT_ID"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
DEPLOYER_EMAIL="${DEPLOYER}@${PROJECT_ID}.iam.gserviceaccount.com"
```

## 1. Enable the APIs

```bash
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com
```

## 2. Create the state bucket

```bash
gcloud storage buckets create "gs://${STATE_BUCKET}" \
  --location="$REGION" \
  --uniform-bucket-level-access \
  --public-access-prevention

gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
```

## 3. Create the deployer service account

```bash
gcloud iam service-accounts create "$DEPLOYER" --display-name="GitHub Actions deployer"

for role in roles/run.admin roles/artifactregistry.admin roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEPLOYER_EMAIL}" --role="$role" --condition=None
done

gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="serviceAccount:${DEPLOYER_EMAIL}" --role=roles/storage.objectAdmin
```

`roles/iam.serviceAccountUser` lets the deployer start Cloud Run as its runtime
service account. `roles/run.admin` includes making the service public.

## 4. Set up Workload Identity Federation

The attribute condition only accepts tokens issued to this repository.

```bash
gcloud iam workload-identity-pools create "$POOL" \
  --location=global --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
  --location=global \
  --workload-identity-pool="$POOL" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment" \
  --attribute-condition="assertion.repository == '${REPO}'"

gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER_EMAIL" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"
```

## 5. Optional: a dedicated runtime service account

Without one, Cloud Run runs as the project's default compute service account,
which usually holds broad permissions. The app needs no Google APIs, so its
runtime account needs no roles.

```bash
gcloud iam service-accounts create multi-cloud-app-runtime --display-name="multi-cloud-app runtime"
```

## 6. Configure the GitHub Environments

Repeat for `prod`. Each environment keeps its own state, so give each its own
repository and service name (as below), or better, its own project.

```bash
env=dev
gh api --method PUT "repos/${REPO}/environments/${env}" >/dev/null

gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --repo "$REPO" --env "$env" \
  --body "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
gh secret set GCP_SERVICE_ACCOUNT --repo "$REPO" --env "$env" --body "$DEPLOYER_EMAIL"

gh variable set GCP_PROJECT_ID      --repo "$REPO" --env "$env" --body "$PROJECT_ID"
gh variable set GCP_REGION          --repo "$REPO" --env "$env" --body "$REGION"
gh variable set GCP_REPOSITORY      --repo "$REPO" --env "$env" --body "multi-cloud-app-${env}"
gh variable set GCP_SERVICE_NAME    --repo "$REPO" --env "$env" --body "multi-cloud-app-${env}"
gh variable set GCP_TF_STATE_BUCKET --repo "$REPO" --env "$env" --body "$STATE_BUCKET"
# Only if you created the runtime account in step 5
gh variable set GCP_RUNTIME_SERVICE_ACCOUNT --repo "$REPO" --env "$env" \
  --body "multi-cloud-app-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
```

For `prod`, add required reviewers and restrict deployment branches to `main` in
**Settings > Environments > prod**.

## 7. Deploy

```bash
gh workflow run deploy-gcp.yml --repo "$REPO" -f environment=dev
gh run watch --repo "$REPO"
```

The workflow:

1. Exchanges its OIDC token for short-lived credentials as the deployer.
2. Applies the Artifact Registry repository (phase 1).
3. Builds the image with the commit SHA as its tag and version, and pushes it.
4. Applies the Cloud Run service and its public invoker binding (phase 2).
5. Polls `<service-url>/health` until it reports the commit SHA, then records
   the URL in the run summary and on the environment.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `Permission 'iam.serviceAccounts.getAccessToken' denied` | The `workloadIdentityUser` binding is missing, or the repository in it does not match exactly (it is case-sensitive). |
| `The caller does not have permission` on the state bucket | The bucket binding from step 3 is missing. |
| `API has not been used in project` | An API from step 1 is not enabled yet; enabling can take a minute. |
| `cannot destroy service without setting deletion_protection=false` | OpenTofu protects the Cloud Run service from deletion by default. Use the gcloud tear-down below, or apply once with `TF_VAR_deletion_protection=false` and the deployed image tag before destroying. |

## Tear down

Delete the service and the registry, then the environment's state:

```bash
gcloud run services delete "multi-cloud-app-dev" --region="$REGION" --quiet
gcloud artifacts repositories delete "multi-cloud-app-dev" --location="$REGION" --quiet
gcloud storage rm --recursive "gs://${STATE_BUCKET}/multi-cloud-app-dev/dev"
```
