# PostgreSQL for the cluster. The pods sign in with EKS Pod Identity: the service's role may
# only connect as app_user with IAM tokens, and the migration job's role may only read the
# administrator password that RDS keeps in Secrets Manager.
module "database" {
  source = "../modules/aws-database"

  name               = local.name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.database_subnets
  client_cidr_blocks = module.vpc.private_subnets_cidr_blocks
  instance_class     = var.database_instance_class
  alert_email        = var.alert_email
  kms_key_arn        = local.kms_key_arn
}

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name}-app"
  description        = "The service's pods in ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy" "app_database" {
  name   = "database-connect"
  role   = aws_iam_role.app.id
  policy = module.database.connect_policy_json
}

resource "aws_eks_pod_identity_association" "app" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.kubernetes_namespace
  service_account = var.release_name
  role_arn        = aws_iam_role.app.arn
}

resource "aws_iam_role" "migration" {
  name               = "${local.name}-migrate"
  description        = "The database migration job in ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy" "migration_secret" {
  name   = "database-admin-secret"
  role   = aws_iam_role.migration.id
  policy = module.database.admin_secret_policy_json
}

resource "aws_eks_pod_identity_association" "migration" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.kubernetes_namespace
  service_account = "${var.release_name}-migrate"
  role_arn        = aws_iam_role.migration.arn
}
