# GCP deployment guide

This guide sets up everything the **Deploy to GCP** workflow needs. You create
the state bucket, the deployer service account and Workload Identity
Federation by hand. OpenTofu creates the Artifact Registry repository, a VPC, a
Cloud SQL for PostgreSQL instance with a private IP, the service accounts the
service and its migration job run as, the migration job and the Cloud Run
service. Do not create those yourself, or the first apply will fail because they
already exist.

No service account key or database password is ever created; GitHub Actions
exchanges its OIDC token for short-lived Google credentials, and the service signs
in to Cloud SQL with IAM.

## Prerequisites

- A GCP project with billing enabled
- Google Cloud CLI, signed in with `gcloud auth login`
- GitHub CLI, signed in with `gh auth login`

```bash
PROJECT_ID="<project-id>"
REGION="us-central1"
REPO="Naresh1401/enterprise-multi-cloud"
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
  compute.googleapis.com \
  sqladmin.googleapis.com \
  servicenetworking.googleapis.com \
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

for role in roles/run.admin roles/artifactregistry.admin roles/cloudsql.admin \
  roles/compute.networkAdmin roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEPLOYER_EMAIL}" --role="$role" --condition=None
done

# Granting the database identities their Cloud SQL roles, and nothing else
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOYER_EMAIL}" --role=roles/resourcemanager.projectIamAdmin \
  --condition="title=cloud-sql-roles-only,expression=api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(['roles/cloudsql.client', 'roles/cloudsql.instanceUser'])"

gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="serviceAccount:${DEPLOYER_EMAIL}" --role=roles/storage.objectAdmin
```

- `roles/run.admin` creates the service and the migration job, and makes the
  service public.
- `roles/cloudsql.admin` creates the instance and its IAM database users.
- `roles/compute.networkAdmin` creates the VPC and the private services peering
  that gives the instance its private IP.
- `roles/iam.serviceAccountAdmin` creates the service accounts the service and
  the migration job run as; `roles/iam.serviceAccountUser` lets Cloud Run run as them.
- The conditional Project IAM Admin binding lets the deployer grant those two
  accounts `roles/cloudsql.client` and `roles/cloudsql.instanceUser` on the new
  instance, and no other role.

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

## 5. Configure the GitHub Environments

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
```

For `prod`, add required reviewers and restrict deployment branches to `main` in
**Settings > Environments > prod**.

## 6. Deploy

```bash
gh workflow run deploy-gcp.yml --repo "$REPO" -f environment=dev
gh run watch --repo "$REPO"
```

The workflow:

1. Exchanges its OIDC token for short-lived credentials as the deployer.
2. Applies the Artifact Registry repository (phase 1).
3. Builds the image with the commit SHA as its tag and version, and pushes it.
4. Applies the rest (phase 2): the VPC, the Cloud SQL instance, the service
   accounts, the migration job, which OpenTofu runs once and waits for, and
   then the Cloud Run service and its public invoker binding. The first run takes
   15 minutes or more while Cloud SQL is created.
5. Polls `<service-url>/ready` until it reports the commit SHA and a working
   database, then records the URL in the run summary and on the environment.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `Permission 'iam.serviceAccounts.getAccessToken' denied` | The `workloadIdentityUser` binding is missing, or the repository in it does not match exactly (it is case-sensitive). |
| `The caller does not have permission` on the state bucket | The bucket binding from step 3 is missing. |
| `API has not been used in project` | An API from step 1 is not enabled yet; enabling can take a minute. |
| `cannot destroy service without setting deletion_protection=false` | OpenTofu protects the Cloud Run service, the migration job and the Cloud SQL instance from deletion by default. Use the gcloud tear-down below, or apply once with `TF_VAR_deletion_protection=false` and the deployed image tag before destroying. |
| The migration job fails | Its log is under **Cloud Run > Jobs > `<service>-migrate`**. A first run right after the instance was created can fail while IAM changes propagate; run the workflow again. |

## Tear down

Delete the service and the registry, then the environment's state:

```bash
gcloud run services delete "multi-cloud-app-dev" --region="$REGION" --quiet
gcloud run jobs delete "multi-cloud-app-dev-migrate" --region="$REGION" --quiet
gcloud sql instances patch "multi-cloud-app-dev" --no-deletion-protection --quiet
gcloud sql instances delete "multi-cloud-app-dev" --quiet
gcloud artifacts repositories delete "multi-cloud-app-dev" --location="$REGION" --quiet
gcloud storage rm --recursive "gs://${STATE_BUCKET}/multi-cloud-app-dev/dev"
```
