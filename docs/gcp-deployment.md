# GCP deployment guide

This guide explains how to deploy the app to Google Cloud Platform using GitHub Actions, Artifact Registry, and Cloud Run.

## Prerequisites

Before running the GCP workflow, you need:

- a GCP project
- billing enabled for that project
- Google Cloud SDK installed locally
- Artifact Registry enabled
- Cloud Run enabled
- a GitHub repository with Actions secrets configured

## 1. Authenticate locally

```bash
gcloud auth login
gcloud config set project <PROJECT_ID>
gcloud projects describe <PROJECT_ID>
```

## 2. Enable required services

```bash
gcloud services enable run.googleapis.com artifactregistry.googleapis.com
```

## 3. Create the Artifact Registry repository

```bash
gcloud artifacts repositories create multi-cloud-app \
  --repository-format=docker \
  --location=us-central1 \
  --description="Multi-cloud app registry"
```

## 4. Create the service account for GitHub Actions

```bash
gcloud iam service-accounts create github-actions-multi-cloud \
  --project=<PROJECT_ID>
```

Grant the required permissions:

```bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="serviceAccount:github-actions-multi-cloud@<PROJECT_ID>.iam.gserviceaccount.com" \
  --role="roles/run.admin"

gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="serviceAccount:github-actions-multi-cloud@<PROJECT_ID>.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.admin"

gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="serviceAccount:github-actions-multi-cloud@<PROJECT_ID>.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
```

Configure Workload Identity Federation for the GitHub repository and branch.
Do not create a service-account JSON key. Add these values to the selected
GitHub Environment:

- Variable: `GCP_PROJECT_ID`
- Variable: `GCP_REGION`
- Variable: `GCP_REPOSITORY`
- Variable: `GCP_SERVICE_NAME`
- Variable: `GCP_TF_STATE_BUCKET`
- Secret: `GCP_WORKLOAD_IDENTITY_PROVIDER`
- Secret: `GCP_SERVICE_ACCOUNT`

## 5. Validate the Terraform files

The GCP Terraform configuration is in:

- `infra/gcp/main.tf`
- `infra/gcp/variables.tf`

These files provision the Artifact Registry repository and Cloud Run service.

## 6. Run the workflow

Trigger the GCP deployment workflow:

- `.github/workflows/deploy-gcp.yml`

This workflow does the following:

1. authenticates to GCP
2. runs Terraform
3. builds the Docker image
4. pushes it to Artifact Registry
5. deploys it to Cloud Run

## 8. Confirm the live URL

After the workflow finishes, run:

```bash
gcloud run services describe multi-cloud-app \
  --region=us-central1 \
  --format='value(status.url)'
```

Then open the returned URL and verify:

```text
https://<service-url>/health
```

## 9. Production notes

For production, add:

- protected deployment approvals
- separate staging and prod projects or services
- Cloud Monitoring alerts
- Cloud Logging configuration
- cost and quota checks

## Troubleshooting

Common issues:

- project not enabled for Artifact Registry or Cloud Run
- missing IAM roles on the service account
- invalid JSON key in GitHub secrets
- region mismatch between Terraform and deployment commands

If deployment fails, check the workflow logs and confirm the project ID, region, and repository names all match exactly.
