variable "name" {
  type        = string
  description = "Name of the database instance and its resources, for example multi-cloud-dev"
}

variable "environment" {
  type        = string
  description = "dev or prod; prod gets Multi-AZ, longer backups and deletion protection"
}

variable "vpc_id" {
  type        = string
  description = "VPC the database lives in"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnets in at least two availability zones"
}

variable "client_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Security groups allowed to connect, for example the ECS tasks'"
}

variable "client_cidr_blocks" {
  type        = list(string)
  default     = []
  description = "Address ranges allowed to connect, for example the EKS pod subnets"
}

variable "instance_class" {
  type        = string
  default     = "db.t4g.micro"
  description = "RDS instance class"
}

variable "engine_version" {
  type        = string
  default     = "17"
  description = "PostgreSQL version; a major version gets the latest minor release"
}

variable "allocated_storage" {
  type        = number
  default     = 20
  description = "Initial storage in GiB"
}

variable "max_allocated_storage" {
  type        = number
  default     = 100
  description = "Storage autoscaling limit in GiB"
}

variable "database_name" {
  type        = string
  default     = "app"
  description = "Database the service uses"
}

variable "admin_username" {
  type        = string
  default     = "dbadmin"
  description = "RDS administrator, used only by the migration job"
}

variable "app_role" {
  type        = string
  default     = "app_user"
  description = "PostgreSQL role the service signs in as with IAM; the migration job creates it"
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email address for CPU, storage, connection and (prod) failover alarms; empty leaves them unmonitored"
}

variable "cpu_alarm_threshold" {
  type        = number
  default     = 80
  description = "CPU percent sustained for 15 minutes that triggers the CPU alarm"
}

variable "connection_alarm_threshold" {
  type        = number
  default     = 80
  description = "Open connections sustained for 15 minutes that triggers the connections alarm"
}
