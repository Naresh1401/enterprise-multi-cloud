# Kubernetes deployment guide

One Helm chart, [`deploy/helm/multi-cloud-app`](../deploy/helm/multi-cloud-app), runs the
service on GKE Autopilot, AKS or EKS Auto Mode. **Deploy to Kubernetes** creates the
cluster and its registry with OpenTofu the first time, builds and pushes the image,
installs the chart with that cloud's values, and finishes only when `/health` reports
the deployed commit.

## What the chart sets up

- A Deployment of the image with rolling updates that never drop below the desired
  replicas, startup, readiness and liveness probes on `/health`, and replicas spread
  across zones
- Pods that run as UID 10001 with a read-only root filesystem, no Linux capabilities,
  no privilege escalation, the RuntimeDefault seccomp profile and no service account token
- CPU and memory requests and a memory limit
- A HorizontalPodAutoscaler (2 to 6 replicas at 70% CPU) and a PodDisruptionBudget that
  keeps one replica up during node maintenance
- A NetworkPolicy that admits only the HTTP port and lets nothing out but DNS
- A Service (ClusterIP by default), an optional Ingress, and a `helm test` connection check

Each cloud's values file only changes how traffic gets in:

| Values file | Load balancer |
| --- | --- |
| `values-gke.yaml` | External passthrough Network Load Balancer |
| `values-aks.yaml` | Azure Standard Load Balancer, probing `/health` |
| `values-eks.yaml` | Internet-facing Network Load Balancer from EKS Auto Mode, targeting pod IPs |

## The clusters

| Folder | Cluster | Also creates |
| --- | --- | --- |
| [`infra/gke`](../infra/gke) | GKE Autopilot, regional, REGULAR release channel, private nodes | VPC and subnet with pod and service ranges, Cloud NAT, Artifact Registry with pull access for the nodes |
| [`infra/aks`](../infra/aks) | AKS with an autoscaling Azure Linux system pool, Azure CNI overlay with Cilium network policy, workload identity, stable automatic upgrades | Resource group, Container Registry with `AcrPull` for the nodes |
| [`infra/eks`](../infra/eks) | EKS Auto Mode (AWS runs the nodes, load balancing and storage), control-plane logs, KMS-encrypted secrets | VPC across three zones with NAT, ECR repository |

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

- **Google Cloud:** the `container.googleapis.com` and `compute.googleapis.com` APIs enabled,
  and the deployer service account granted Kubernetes Engine Admin, Compute Network Admin,
  Artifact Registry Administrator and Service Account User.
- **Azure:** the `Microsoft.ContainerService` resource provider registered, and the deployment
  identity able to create resource groups (Contributor on the subscription) and the `AcrPull`
  assignment (Role Based Access Control Administrator limited to `AcrPull`).
- **AWS:** nothing extra; the role from the AWS guide covers EKS.

## Deploy

Run **Actions > Deploy to Kubernetes**, choose the cloud and the environment. The first
run takes 20 minutes or more while the cluster is created; later runs only build, push
and upgrade the release. The run summary shows the cluster, the load balancer's address
once it is ready, and the commit the pods report.

To look at the release yourself after a run:

```bash
# GKE
gcloud container clusters get-credentials multi-cloud-dev --region "$GCP_REGION"
# AKS
az aks get-credentials --resource-group "$AKS_RESOURCE_GROUP" --name multi-cloud-dev
# EKS
aws eks update-kubeconfig --name multi-cloud-dev --region "$AWS_REGION"

kubectl get pods,services --namespace multi-cloud-app
helm test multi-cloud-app --namespace multi-cloud-app
```

## Try it locally

With Docker, kind and Helm installed:

```bash
kind create cluster
docker build --build-arg APP_VERSION=local --tag multi-cloud-app:local .
kind load docker-image multi-cloud-app:local
helm install demo deploy/helm/multi-cloud-app --set image.tag=local --wait
kubectl port-forward service/demo-multi-cloud-app 8080:80 &
curl -s localhost:8080/health
```

CI does the same on every change: it builds the image from the commit, installs the chart
on a kind cluster, checks that `/health` reports that commit, and runs `helm test`.

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

GKE clusters have deletion protection on by default; apply with
`deletion_protection = false` before destroying.
