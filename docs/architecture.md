# Architecture notes

This repository illustrates a pattern where one application is built once and deployed to multiple cloud environments.

## Main components

- GitHub repository as the source of truth
- GitHub Actions for CI/CD orchestration
- Python Flask app as the sample workload
- Docker image as the packaged artifact
- Terraform for Azure and GCP provisioning
- Azure Container Registry and GCP Artifact Registry for image storage

## Deployment pattern

1. Code is committed to GitHub
2. CI workflow runs tests and Docker build
3. Manual or automated deployment workflow starts
4. Cloud credentials are used to authenticate
5. Infrastructure is applied via Terraform
6. Application is deployed to the target cloud

## Benefits

- avoids platform lock-in
- teaches cloud-native delivery fundamentals
- provides a clear architecture for real-world deployments
- works as a starting point for production hardening

## Production upgrades

To move from blueprint to production, add:
- approval gates
- environment-specific variables
- image signing
- vulnerability scans
- blue/green or canary deploys
- centralized monitoring and dashboards
