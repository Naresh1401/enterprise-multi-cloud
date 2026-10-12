# One customer-managed KMS key for everything this target encrypts with its own key: the
# image repository, container logs and the database (storage and Performance Insights). Off by
# default (enable_customer_managed_key): AWS's own keys encrypt all of them already, just not
# with a key this account controls, rotates and can see usage of in CloudTrail.
#
# Enabling it after the database or the repository already exist forces OpenTofu to replace
# them: neither RDS nor ECR can re-encrypt existing data with a different key. Set it before
# the first apply, not after. The log group can change keys in place at any time.
resource "aws_kms_key" "this" {
  count = var.enable_customer_managed_key ? 1 : 0

  description         = "${local.name} image repository, container logs and database"
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
      {
        # CloudWatch Logs needs its own grant, scoped to this account's log groups; ECR and RDS
        # instead use grants OpenTofu's own credentials create, which the statement above covers
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.region}.amazonaws.com" }
        Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
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
