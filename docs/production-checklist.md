# Production checklist

Use this before treating a deployment as production.

## Repository

- [ ] `main` requires pull requests and the **CI/CD** checks to pass
- [ ] The `prod` environment has required reviewers and only allows `main`
- [ ] Dependabot pull requests (Actions, pip, Docker) are reviewed weekly

## Identity and access

- [ ] Azure federated credentials exist for each environment subject:
      `repo:<owner>/<repo>:environment:dev` and `...:prod`
- [ ] The Azure deployment identity's RBAC Administrator role is constrained to `AcrPull`
- [ ] The GCP Workload Identity provider only accepts this repository
- [ ] No cloud keys or client secrets are stored in GitHub
- [ ] Cloud Run runs as a dedicated runtime service account (`GCP_RUNTIME_SERVICE_ACCOUNT`)

## State and infrastructure

- [ ] OpenTofu state stores are versioned and closed to public access
- [ ] Each environment has its own state, resource names, and ideally its own
      subscription or project
- [ ] Registry names are unique and recorded in the environment variables

## Delivery

- [ ] CI is green for the commit being deployed
- [ ] The deployment run summary shows the expected commit SHA and URL
- [ ] `/health` on the live URL reports that commit

## Operations

- [ ] Alerts exist for error rate, latency and restarts
      (Cloud Monitoring and Azure Monitor)
- [ ] Budgets and cost alerts are set for both clouds
- [ ] Registry clean-up policies keep a bounded number of images

## Rollback

- [ ] The previous good commit SHA is known before deploying
- [ ] To roll back, dispatch the deployment workflow from that commit; the
      image is rebuilt from the same source and verified the same way
- [ ] Health is re-checked after a rollback and the cause is written up
