variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment name, used for APP_ENV, resource names and tags"
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "service_name" {
  type        = string
  default     = "multi-cloud-app"
  description = "ECS service name, also the prefix for the cluster, load balancer and roles"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,21}$", var.service_name))
    error_message = "service_name must be up to 22 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "image_tag" {
  type        = string
  default     = "unset"
  description = "Image tag to run, the commit SHA; the deploy workflow sets it"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "CIDR block for the VPC"
}

variable "task_cpu" {
  type        = number
  default     = 256
  description = "Fargate task CPU units"
}

variable "task_memory" {
  type        = number
  default     = 1024
  description = "Fargate task memory in MiB"
}

variable "database_instance_class" {
  type        = string
  default     = "db.t4g.micro"
  description = "RDS instance class; size it for tasks x workers x 4 connections"
}

variable "desired_count" {
  type        = number
  default     = 2
  description = "Number of tasks"
}

variable "certificate_arn" {
  type        = string
  default     = ""
  description = "ACM certificate for HTTPS; empty serves plain HTTP"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags for every resource"
}
