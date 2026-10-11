# Production checklist

Use this before treating a deployment as production.

## Repository

- [ ] `main` requires pull requests and the **CI** checks to pass
- [ ] The `prod` environment has required reviewers and only allows `main`
- [ ] Dependabot pull requests (Actions, pip, Docker) are reviewed weekly

## Identity and access

- [ ] Azure federated credentials exist for each environment subject:
      `repo:<owner>/<repo>:environment:dev` and `...:prod`
- [ ] The Azure deployment identity's RBAC Administrator role is constrained to `AcrPull`
- [ ] The GCP Workload Identity provider only accepts this repository
- [ ] The AWS deploy role trusts only `repo:<owner>/<repo>:environment:dev` and `...:prod`,
      and outside a sandbox account its policy is limited to the services it deploys
- [ ] No cloud keys or client secrets are stored in GitHub
- [ ] The deploy identities' role-granting permissions stay limited to the roles OpenTofu
      grants (`AcrPull` and Network Contributor on Azure, the two Cloud SQL roles on Google Cloud)

## State and infrastructure

- [ ] OpenTofu state stores are versioned and closed to public access
- [ ] Each environment has its own state, resource names, and ideally its own
      subscription or project
- [ ] Registry names are unique and recorded in the environment variables

## Kubernetes and load balancers

- [ ] `api_allowed_cidrs` narrows the GKE, AKS and EKS API endpoints, or self-hosted runners
      use private endpoints
- [ ] Public traffic is served over HTTPS: `AWS_CERTIFICATE_ARN` on ECS, and an Ingress with a
      certificate on the clusters
- [ ] Cluster upgrades (GKE release channel, AKS auto-upgrade, EKS version) are watched and
      the chart is re-tested on the new version
- [ ] Clusters that aren't in use are destroyed (`helm uninstall`, then `tofu destroy`)

## Database

- [ ] The database fits `replicas x workers x (DB_POOL_SIZE + DB_MAX_OVERFLOW)` connections
      plus a few for migrations, and the HPA's `maxReplicas` keeps within that
- [ ] `prod` runs highly available (Multi-AZ, regional or zone-redundant) with 14 days of
      backups and deletion protection, which the `prod` environment name turns on
- [ ] A restore from backup has been tried, and how long it takes is known
- [ ] Migrations add before they remove, so the previous version keeps working while the new
      one rolls out ([database.md](database.md#writing-a-migration))
- [ ] `/api/items` sits behind authentication before it holds real data
- [ ] Alerts exist for connections, CPU, storage and replication lag

## Delivery

- [ ] CI is green for the commit being deployed
- [ ] The deployment run summary shows the expected commit SHA and URL
- [ ] `/ready` on the live URL reports that commit and `"database": "ok"`

## Operations

- [ ] Alerts exist for error rate, latency and restarts
      (CloudWatch, Cloud Monitoring and Azure Monitor)
- [ ] Budgets and cost alerts are set for all three clouds
- [ ] Registry clean-up policies keep a bounded number of images

## Rollback

- [ ] The previous good commit SHA is known before deploying
- [ ] To roll back, dispatch the deployment workflow from that commit; the
      image is rebuilt from the same source and verified the same way
- [ ] Health is re-checked after a rollback and the cause is written up
