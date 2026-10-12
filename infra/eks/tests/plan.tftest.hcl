mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
      arn        = "arn:aws:sts::111122223333:assumed-role/github-deploy/session"
    }
  }
  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::111122223333:role/github-deploy"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:111122223333:log-group:mock"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/mock"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:111122223333:key/mock"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::111122223333:policy/mock"
    }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:us-east-1:111122223333:cluster/mock"
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/MOCK" }] }]
      certificate_authority = [{ data = "bW9jaw==" }]
    }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:111122223333:secret:rds!db-mock"
        kms_key_id    = "arn:aws:kms:us-east-1:111122223333:key/mock"
        secret_status = "active"
      }]
    }
  }
}

mock_provider "tls" {}

variables {
  environment = "dev"
}

run "dev" {
  command = plan

  assert {
    condition = (
      aws_eks_pod_identity_association.app.namespace == "multi-cloud-app" &&
      aws_eks_pod_identity_association.app.service_account == "multi-cloud-app" &&
      aws_eks_pod_identity_association.migration.service_account == "multi-cloud-app-migrate"
    )
    error_message = "The service and the migration job must each get their own role through EKS Pod Identity."
  }
  assert {
    condition = (
      one(one(data.aws_iam_policy_document.pod_identity_assume.statement).principals).identifiers == toset(["pods.eks.amazonaws.com"]) &&
      one(data.aws_iam_policy_document.pod_identity_assume.statement).actions == toset(["sts:AssumeRole", "sts:TagSession"])
    )
    error_message = "The pod roles must trust only EKS Pod Identity."
  }
  assert {
    condition     = aws_iam_role.app.name == "multi-cloud-dev-app" && aws_iam_role.migration.name == "multi-cloud-dev-migrate"
    error_message = "The service and the migration job must have separate roles."
  }
  assert {
    condition = (
      aws_ecr_repository.app.name == "multi-cloud-dev-app" &&
      aws_ecr_repository.app.image_tag_mutability == "IMMUTABLE" &&
      aws_ecr_repository.app.image_scanning_configuration[0].scan_on_push
    )
    error_message = "Images must be immutable and scanned on push."
  }
  assert {
    condition = (
      yamldecode(output.helm_values).database.enabled &&
      yamldecode(output.helm_values).database.region == "us-east-1" &&
      yamldecode(output.helm_values).database.user == "app_user" &&
      yamldecode(output.helm_values).database.migrations.user == "dbadmin" &&
      startswith(yamldecode(output.helm_values).database.migrations.passwordSecretArn, "arn:aws:secretsmanager:")
    )
    error_message = "The chart values must point the release at the database and the administrator's secret."
  }
  assert {
    condition = (
      [for peer in yamldecode(output.helm_values).database.egress.to : peer.ipBlock.cidr] ==
      ["10.30.192.0/24", "10.30.193.0/24", "10.30.194.0/24"]
    )
    error_message = "The pods may only reach the database subnets on the database port."
  }
}
