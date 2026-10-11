# AWS deployment guide

This guide sets up everything **Deploy to AWS** (ECS Fargate) and the `eks` option of
**Deploy to Kubernetes** need. You create only two things by hand: the S3 bucket that
holds OpenTofu state, and the IAM role GitHub Actions assumes. OpenTofu creates
everything else (VPC, ECR repository, ECS cluster, load balancer and service, or the EKS
cluster). Do not create those resources yourself, or the first apply will fail because
they already exist.

## Prerequisites

- An AWS account where you can create IAM roles and S3 buckets
- AWS CLI v2, signed in (`aws sts get-caller-identity` works)
- GitHub CLI, signed in with `gh auth login`

Set these once in your shell. The bucket name must be globally unique.

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="us-east-1"
REPO="Naresh1401/enterprise-multi-cloud"
STATE_BUCKET="<unique-state-bucket-name>"
ROLE_NAME="github-enterprise-multi-cloud"
```

## 1. Create the state bucket

```bash
if [ "$REGION" = us-east-1 ]; then
  aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION"
else
  aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi
aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

OpenTofu locks the state with a lock file in the same bucket (`use_lockfile`), so no
DynamoDB table is needed. That needs OpenTofu 1.10 or later, which the workflows install.

## 2. Let GitHub Actions sign in with OIDC

Create the GitHub identity provider once per account (skip this if it already exists):

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

Create the role, trusting only this repository's `dev` and `prod` environments:

```bash
cat > trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": [
          "repo:${REPO}:environment:dev",
          "repo:${REPO}:environment:prod"
        ]
      }
    }
  }]
}
EOF
aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://trust.json
```

## 3. Give the role what it deploys

The role creates a VPC with NAT, ECR repositories, an ECS cluster with a load balancer or
an EKS cluster with its IAM roles and KMS key, CloudWatch log groups, and reads and writes
the state bucket. In a dedicated sandbox account the simplest choice is
`AdministratorAccess`:

```bash
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

In a shared account, attach a policy limited to EC2 (VPC), ECR, ECS, Elastic Load
Balancing, EKS, RDS, Secrets Manager (RDS creates the database administrator's secret on
the role's behalf), IAM (roles and policies named after the service or cluster), KMS,
CloudWatch Logs and the state bucket instead.

## 4. Configure the GitHub Environments

```bash
for env in dev prod; do
  gh variable set AWS_REGION --env "$env" --body "$REGION" --repo "$REPO"
  gh variable set AWS_TF_STATE_BUCKET --env "$env" --body "$STATE_BUCKET" --repo "$REPO"
  gh variable set AWS_SERVICE_NAME --env "$env" --body "multi-cloud-app" --repo "$REPO"
  gh secret set AWS_ROLE_ARN --env "$env" --repo "$REPO" \
    --body "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
done
```

Each environment gets its own state file and resource names (the environment is part of
every name), so `dev` and `prod` can share an account.

For HTTPS on the ECS load balancer, request or import an ACM certificate for your domain,
set `AWS_CERTIFICATE_ARN` to its ARN, and point the domain at the load balancer. Port 80
then redirects to HTTPS.

## 5. Deploy

- **Actions > Deploy to AWS** for ECS Fargate. The run creates the VPC, ECR, an RDS
  PostgreSQL database, the ECS cluster, load balancer and service, waits until the new tasks
  are steady, then checks that `/ready` reports the commit and a working database. Each task
  first runs the migrations in its `migrate` container, signed in as the RDS administrator
  with the password RDS generates and keeps in Secrets Manager; the app container then signs
  in as `app_user` with IAM tokens.
- **Actions > Deploy to Kubernetes**, cloud `eks`, for EKS Auto Mode. See
  [kubernetes-deployment.md](kubernetes-deployment.md).

## Troubleshooting

- **AccessDenied while assuming the role:** the trust policy's `sub` must match
  `repo:<owner>/<repo>:environment:<env>` exactly, and the workflow job must use that environment.
- **The service never becomes steady:** the ECS console's service events show why tasks stop;
  the container logs are in the `/ecs/<service>-<environment>` log group, with the migrations
  under the `migrate/` streams. If the migrate container fails, the app container doesn't
  start, and a failed deployment rolls back to the previous task definition automatically.
- **The first apply takes 10 minutes or more:** RDS is creating the database.
- **`tofu destroy` stops at the ECR repository in prod:** prod repositories keep their images;
  delete them first if you really mean to remove the repository.
