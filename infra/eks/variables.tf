variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment name, used in resource names and tags"
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "cluster_name" {
  type        = string
  default     = "multi-cloud"
  description = "EKS cluster name; the environment is appended"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be up to 31 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "kubernetes_version" {
  type        = string
  default     = null
  description = "Kubernetes version, for example 1.35; null uses the EKS default"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.30.0.0/16"
  description = "CIDR block for the cluster VPC"
}

variable "api_allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDR blocks allowed to reach the public Kubernetes API endpoint"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags for every resource"
}

variable "database_instance_class" {
  type        = string
  default     = "db.t4g.micro"
  description = "RDS instance class; size it for replicas x workers x 4 connections"
}

variable "kubernetes_namespace" {
  type        = string
  default     = "multi-cloud-app"
  description = "Namespace the deploy workflow installs the chart in"
}

variable "release_name" {
  type        = string
  default     = "multi-cloud-app"
  description = "Helm release name; the chart names its service accounts after it"
}
