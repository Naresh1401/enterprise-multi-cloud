output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name, for aws eks update-kubeconfig"
}

output "repository_url" {
  value       = aws_ecr_repository.app.repository_url
  description = "ECR repository the deploy workflow pushes to (named <cluster_name>-<environment>-app)"
}

output "database_host" {
  value       = module.database.address
  description = "RDS endpoint"
}

output "helm_values" {
  description = "Chart values that connect the release to this cluster's database"
  value = yamlencode({
    database = {
      enabled = true
      host    = module.database.address
      port    = module.database.port
      name    = module.database.database_name
      user    = module.database.app_role
      region  = var.region
      migrations = {
        user              = module.database.admin_username
        passwordSecretArn = module.database.admin_secret_arn
      }
      egress = {
        to = [for cidr in module.vpc.database_subnets_cidr_blocks : { ipBlock = { cidr = cidr } }]
      }
    }
  })
}
