#!/usr/bin/env bash
# Prints the one-time AWS setup. docs/aws-deployment.md has the exact commands.
set -euo pipefail

cat <<'STEPS'
AWS bootstrap (one time, see docs/aws-deployment.md)

1. Create a versioned, encrypted S3 bucket for OpenTofu state with public access
   blocked. OpenTofu locks state with a lock file in the bucket; no DynamoDB table.
2. Create the GitHub OIDC identity provider (token.actions.githubusercontent.com,
   audience sts.amazonaws.com) if the account doesn't have it.
3. Create the deploy role, trusting only repo:<owner>/<repo>:environment:dev and
   repo:<owner>/<repo>:environment:prod.
4. Give the role what it deploys: VPC, ECR, ECS, load balancing, EKS, RDS,
   Secrets Manager, IAM roles, KMS, CloudWatch Logs and the state bucket.
5. Add AWS_REGION, AWS_TF_STATE_BUCKET and AWS_SERVICE_NAME as variables, and
   AWS_ROLE_ARN as a secret, in each GitHub Environment.
6. Run "Deploy to AWS" (ECS Fargate) or "Deploy to Kubernetes" with cloud eks, and
   confirm the run summary shows the commit SHA.

Do not create the VPC, ECR repository, RDS database, ECS cluster, load balancer or
EKS cluster by hand; OpenTofu creates them.
STEPS
