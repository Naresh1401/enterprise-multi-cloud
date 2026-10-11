# PostgreSQL on Amazon RDS for one deployment target (ECS or EKS): private subnets, TLS only,
# IAM authentication for the service, and an administrator password that RDS generates and
# keeps in Secrets Manager, so it never appears in OpenTofu state or in GitHub.
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

locals {
  prod = var.environment == "prod"
}

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_db_subnet_group" "this" {
  name        = var.name
  description = "Private subnets for the ${var.name} database"
  subnet_ids  = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = "${var.name}-database"
  description = "PostgreSQL from the ${var.name} workloads only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "from_security_groups" {
  for_each = toset(var.client_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from the workloads"
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "from_cidrs" {
  for_each = toset(var.client_cidr_blocks)

  security_group_id = aws_security_group.this.id
  description       = "PostgreSQL from the workload subnets"
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

resource "aws_db_parameter_group" "this" {
  name        = var.name
  family      = "postgres${split(".", var.engine_version)[0]}"
  description = "TLS-only connections for ${var.name}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.admin_username
  # RDS generates the administrator password, stores it in Secrets Manager and rotates it;
  # only the migration job can read it
  manage_master_user_password = true
  # The service signs in with IAM tokens instead of a password
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  multi_az                    = local.prod
  backup_retention_period     = local.prod ? 14 : 7
  backup_window               = "03:00-04:00"
  maintenance_window          = "sun:04:30-sun:05:30"
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  copy_tags_to_snapshot       = true
  apply_immediately           = !local.prod

  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # A non-production database can be destroyed without a final snapshot, so tofu destroy works
  deletion_protection       = local.prod
  skip_final_snapshot       = !local.prod
  final_snapshot_identifier = local.prod ? "${var.name}-final" : null
}

data "aws_iam_policy_document" "connect" {
  statement {
    sid     = "SignInAsTheServiceRole"
    actions = ["rds-db:connect"]
    resources = [
      "arn:${data.aws_partition.current.partition}:rds-db:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.this.resource_id}/${var.app_role}",
    ]
  }
}

data "aws_iam_policy_document" "admin_secret" {
  statement {
    sid       = "ReadTheAdministratorPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }
}
