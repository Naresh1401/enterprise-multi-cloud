# Kubernetes deployment guide

One Helm chart, [`deploy/helm/multi-cloud-app`](../deploy/helm/multi-cloud-app), runs the
service on GKE Autopilot, AKS or EKS Auto Mode. **Deploy to Kubernetes** creates the
cluster, its registry and its PostgreSQL database with OpenTofu the first time, builds and
pushes the image, migrates the database, installs the chart with that cloud's values, and
finishes only when `/ready` reports the deployed commit and a working database.

## What gets deployed

| Cluster | OpenTofu | Architecture, every resource and the checks |
| --- | --- | --- |
| EKS Auto Mode, with RDS | [`infra/eks`](../infra/eks) | [aws-architecture.md](aws-architecture.md#eks-auto-mode) |
| GKE Autopilot, with Cloud SQL | [`infra/gke`](../infra/gke) | [gcp-architecture.md](gcp-architecture.md#gke-autopilot) |
| AKS, with Azure Database for PostgreSQL | [`infra/aks`](../infra/aks) | [azure-architecture.md](azure-architecture.md#aks) |

What the chart puts in each cluster (the Deployment, the migration hook, the network policies,
each cloud's values) and every step of the workflow are in
[kubernetes-architecture.md](kubernetes-architecture.md).

The Kubernetes API endpoints are public because GitHub-hosted runners have no fixed
address. Set the `api_allowed_cidrs` variable to narrow them, or use self-hosted runners
and private endpoints.

## Configuration

The workflow reuses each cloud's sign-in from the [AWS](aws-deployment.md),
[GCP](gcp-deployment.md) and [Azure](azure-deployment.md) guides:

| Cloud | Variables | Secrets |
| --- | --- | --- |
| `gke` | `GCP_PROJECT_ID`, `GCP_REGION`, `GCP_TF_STATE_BUCKET` | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT` |
| `aks` | `AKS_RESOURCE_GROUP`, `AKS_ACR_NAME`, `AZURE_LOCATION`, `AZURE_TF_STATE_RESOURCE_GROUP`, `AZURE_TF_STATE_STORAGE_ACCOUNT`, `AZURE_TF_STATE_CONTAINER` | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| `eks` | `AWS_REGION`, `AWS_TF_STATE_BUCKET` | `AWS_ROLE_ARN` |

On top of what the serverless deployments need, the identities need:

- **Google Cloud:** the `container.googleapis.com`, `compute.googleapis.com`,
  `sqladmin.googleapis.com` and `servicenetworking.googleapis.com` APIs enabled, and the
  deployer service account granted Kubernetes Engine Admin, Compute Network Admin (which
  covers the private services peering), Cloud SQL Admin, Artifact Registry Administrator,
  Service Account Admin and Service Account User. It also grants the database identities
  their Cloud SQL roles, so give it Project IAM Admin limited to those two roles:

  ```bash
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEPLOYER_EMAIL}" --role=roles/resourcemanager.projectIamAdmin \
    --condition="title=cloud-sql-roles-only,expression=api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(['roles/cloudsql.client', 'roles/cloudsql.instanceUser'])"
  ```

- **Azure:** the `Microsoft.ContainerService`, `Microsoft.DBforPostgreSQL` and
  `Microsoft.Network` resource providers registered, and the deployment identity able to
  create resource groups (Contributor on the subscription) and two role assignments: `AcrPull`
  for the nodes and Network Contributor on the node subnet for the cluster. The Role Based
  Access Control Administrator condition in the [Azure guide](azure-deployment.md) allows
  exactly those two.
- **AWS:** nothing extra in a sandbox account; the role from the AWS guide covers EKS, RDS and
  Secrets Manager.

## Deploy

Run **Actions > Deploy to Kubernetes**, choose the cloud and the environment. The first
run takes 30 minutes or more while the cluster and the database are created; later runs
only build, push, migrate and upgrade the release. The run summary shows the cluster, the
load balancer's address once it is ready, the commit the pods report and the state of their
database. The migration Job's log is printed after the upgrade.

To look at the release yourself after a run:

```bash
# GKE
gcloud container clusters get-credentials multi-cloud-dev --region "$GCP_REGION"
# AKS
az aks get-credentials --resource-group "$AKS_RESOURCE_GROUP" --name multi-cloud-dev
# EKS
aws eks update-kubeconfig --name multi-cloud-dev --region "$AWS_REGION"

kubectl get pods,services --namespace multi-cloud-app
kubectl logs job/multi-cloud-app-migrate --namespace multi-cloud-app
helm test multi-cloud-app --namespace multi-cloud-app
```

## Try it locally

With Docker, kind and Helm installed:

```bash
kind create cluster
docker build --build-arg APP_VERSION=local --tag multi-cloud-app:local .
kind load docker-image multi-cloud-app:local
# A throwaway PostgreSQL in the cluster
kubectl apply --filename deploy/kind/postgres.yaml
kubectl rollout status deployment/postgres
helm install demo deploy/helm/multi-cloud-app --values deploy/helm/multi-cloud-app/values-kind.yaml \
  --set image.tag=local --wait
kubectl port-forward service/demo-multi-cloud-app 8080:80 &
curl -s localhost:8080/ready
```

CI does the same on every change: it builds the image from the commit, starts that
PostgreSQL, installs the chart (so the migration hook runs against it), checks that `/ready`
reports the commit, and runs `helm test`.

## Tear down

Clusters, NAT gateways and load balancers cost money while they exist. To remove a cluster,
uninstall the release first so the cloud load balancer goes away, then destroy the
infrastructure with the same backend settings the workflow used:

```bash
helm uninstall multi-cloud-app --namespace multi-cloud-app
cd infra/<gke|aks|eks>
tofu init -backend-config=...   # as in the workflow's "Initialize OpenTofu state" step
tofu destroy
```

GKE clusters and their Cloud SQL instances have deletion protection on by default; apply
with `deletion_protection = false` before destroying. Production RDS instances and flexible
servers are protected too, and RDS takes a final snapshot. A Cloud SQL instance's name can't
be reused for about a week after it is deleted.
