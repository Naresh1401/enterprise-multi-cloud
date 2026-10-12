output "address" {
  value       = aws_db_instance.this.address
  description = "Hostname of the database, which its TLS certificate names"
}

output "port" {
  value       = aws_db_instance.this.port
  description = "PostgreSQL port"
}

output "database_name" {
  value       = aws_db_instance.this.db_name
  description = "Database the service uses"
}

output "app_role" {
  value       = var.app_role
  description = "Role the service signs in as"
}

output "admin_username" {
  value       = aws_db_instance.this.username
  description = "Administrator the migration job signs in as"
}

output "admin_secret_arn" {
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
  description = "Secrets Manager secret holding the administrator password"
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "Security group of the database"
}

output "connect_policy_json" {
  value       = data.aws_iam_policy_document.connect.json
  description = "IAM policy that lets the service sign in as app_role"
}

output "admin_secret_policy_json" {
  value       = data.aws_iam_policy_document.admin_secret.json
  description = "IAM policy that lets the migration job read the administrator password"
}

output "alarm_topic_arn" {
  value       = var.alert_email != "" ? aws_sns_topic.alerts[0].arn : null
  description = "SNS topic the database alarms notify; null when alert_email is empty"
}
