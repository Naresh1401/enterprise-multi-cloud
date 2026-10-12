terraform {
  # use_lockfile (state locking without DynamoDB) needs OpenTofu 1.10 or later
  required_version = ">= 1.10.0"

  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # The EKS module needs 6.59 or later
      version = "~> 6.59"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  name = "${var.cluster_name}-${var.environment}"
  tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "opentofu"
    cluster     = var.cluster_name
  })
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name               = local.name
  cidr               = var.vpc_cidr
  azs                = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnets     = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets    = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
  enable_nat_gateway = true
  single_nat_gateway = var.environment != "prod"

  # Subnets for the database only, with their own route table and no route to the internet
  database_subnets                   = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, 192 + i)]
  create_database_subnet_group       = false
  create_database_subnet_route_table = true

  # Every accepted and rejected connection in the VPC, kept 30 days in CloudWatch Logs
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = 30
  flow_log_max_aggregation_interval               = 60

  # EKS Auto Mode puts internet-facing load balancers in public subnets, internal ones in private
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # GitHub-hosted runners have no fixed address, so the API endpoint is public;
  # api_allowed_cidrs narrows who can reach it
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  # The identity that runs OpenTofu (the deploy role) administers the cluster
  enable_cluster_creator_admin_permissions = true

  # Pods get their AWS credentials from EKS Pod Identity, so no IAM OIDC provider (IRSA) is needed
  enable_irsa = false

  # The control plane and Auto Mode's nodes use the cluster security group EKS creates itself.
  # The module's extra cluster and node groups only serve managed node groups, which this
  # cluster doesn't have, so they would be empty or unused.
  create_security_group      = false
  create_node_security_group = false

  # Auto Mode: AWS runs the nodes, load balancing and storage
  compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  enabled_log_types = ["api", "audit", "authenticator"]

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
}

resource "aws_ecr_repository" "app" {
  name                 = "${local.name}-app"
  image_tag_mutability = "IMMUTABLE"
  # A non-production repository can be deleted with its images, so tofu destroy works
  force_delete = var.environment != "prod"

  image_scanning_configuration {
    scan_on_push = true
  }

  # AWS's own aws/ecr key by default; a customer-managed one only if given one. Set once, at
  # creation: changing it later replaces the repository and its images.
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = local.kms_key_arn != "" ? local.kms_key_arn : null
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 30 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
