output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name, for aws eks update-kubeconfig"
}

output "repository_url" {
  value       = aws_ecr_repository.app.repository_url
  description = "ECR repository the deploy workflow pushes to (named <cluster_name>-<environment>-app)"
}
