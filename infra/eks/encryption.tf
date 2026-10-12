# One customer-managed KMS key for this target's image repository and database (storage and
# Performance Insights). Off by default (enable_customer_managed_key): AWS's own keys encrypt
# both already. Separate from module.eks's own key, which only encrypts Kubernetes secrets.
#
# Enabling it after the database or the repository already exist forces OpenTofu to replace
# them: neither RDS nor ECR can re-encrypt existing data with a different key. Set it before
# the first apply, not after.
resource "aws_kms_key" "this" {
  count = var.enable_customer_managed_key ? 1 : 0

  description         = "${local.name} image repository and database"
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "this" {
  count = var.enable_customer_managed_key ? 1 : 0

  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.this[0].key_id
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  kms_key_arn = var.enable_customer_managed_key ? aws_kms_key.this[0].arn : ""
}
