# Production deployment checklist

This checklist converts the repo from a working blueprint into a real production-ready multi-cloud delivery setup.

## 1. Repository setup

- [ ] Confirm the GitHub repo is the single source of truth
- [ ] Protect the `main` branch with required reviews
- [ ] Set branch protection rules for deployment branches
- [ ] Add required repository secrets for Azure and GCP

## 2. Cloud identity setup

### Azure
- [ ] Create the Azure subscription and resource group
- [ ] Enable Azure Container Registry
- [ ] Enable Azure Container Apps
- [ ] Create or configure the GitHub OIDC identity
- [ ] Set the following secrets:
  - [ ] `AZURE_CLIENT_ID`
  - [ ] `AZURE_TENANT_ID`
  - [ ] `AZURE_SUBSCRIPTION_ID`

### GCP
- [ ] Create the GCP project
- [ ] Enable Artifact Registry and Cloud Run APIs
- [ ] Create a service account with required permissions
- [ ] Download the JSON key
- [ ] Set the following secrets:
  - [ ] `GCP_PROJECT_ID`
  - [ ] `GCP_WORKLOAD_IDENTITY_PROVIDER`
  - [ ] `GCP_SERVICE_ACCOUNT`

## 3. Infrastructure setup

- [ ] Review Terraform defaults in `infra/azure` and `infra/gcp`
- [ ] Check the region matches your target deployment
- [ ] Confirm the registry names are unique and valid
- [ ] Run `terraform plan` before `terraform apply`
- [ ] Validate that the deployed resource names match the workflow variables

## 4. CI validation

- [ ] GitHub Actions run on pull request and push
- [ ] Unit tests pass
- [ ] Docker image builds successfully
- [ ] Container smoke test calls `/health` successfully
- [ ] Artifact is tagged with the Git SHA or semantic version

## 5. Deployment validation

### Azure
- [ ] Workflow logs show successful Azure login
- [ ] Terraform applies without errors
- [ ] Image is pushed to Azure Container Registry
- [ ] Azure Container App is created or updated
- [ ] URL responds successfully on `/health`

### GCP
- [ ] Workflow logs show successful GCP auth
- [ ] Terraform applies without errors
- [ ] Image is pushed to Artifact Registry
- [ ] Cloud Run service is created or updated
- [ ] URL responds successfully on `/health`

## 6. Production hardening

- [ ] Add environment approvals for `prod`
- [ ] Separate dev, staging, and production values
- [ ] Add monitoring, logs, and alerts
- [ ] Define cost alerts and budget limits
- [ ] Add image retention and cleanup policies
- [ ] Record rollback image version before each production release

## 7. Rollback plan

- [ ] Keep the last known good image tag available
- [ ] Validate the previous URL still works after rollback
- [ ] Document the incident and the root cause
- [ ] Re-run smoke tests after rollback

## 8. Release flow

- [ ] Merge to main triggers CI
- [ ] Approval gate is used for production deploys
- [ ] Final post-deploy health validation is performed
- [ ] Production monitoring is checked after rollout

## 9. Final sign-off

- [ ] Team approves the pipeline
- [ ] Workflows are tested in a non-production environment
- [ ] Secrets and permissions are reviewed by the owner
- [ ] Monitoring and alerts are active before production traffic is sent

---

## Example release sequence

1. Build and validate in CI
2. Run staging deployment
3. Validate health and uptime
4. Approve production deployment
5. Push immutable image
6. Deploy to Azure or GCP
7. Confirm health endpoint response
8. Monitor metrics for 15-30 minutes
9. Roll back if needed
