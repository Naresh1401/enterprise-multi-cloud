output "repository_url" {
  value       = aws_ecr_repository.app.repository_url
  description = "ECR repository the deploy workflow pushes to (named <service_name>-<environment>)"
}

output "service_url" {
  value       = "${local.https ? "https" : "http"}://${aws_lb.app.dns_name}"
  description = "Public URL of the load balancer"
}

output "cluster_name" {
  value       = aws_ecs_cluster.app.name
  description = "ECS cluster name"
}

output "database_host" {
  value       = module.database.address
  description = "RDS endpoint"
}
