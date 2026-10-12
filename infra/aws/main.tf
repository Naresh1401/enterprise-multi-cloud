terraform {
  # use_lockfile (state locking without DynamoDB) needs OpenTofu 1.10 or later
  required_version = ">= 1.10.0"

  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  name = "${var.service_name}-${var.environment}"
  tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "opentofu"
    service     = var.service_name
  })
  https           = var.certificate_arn != ""
  tmp_mount       = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
  no_capabilities = { capabilities = { drop = ["ALL"] } }
  # Settings both containers share; the TLS certificate check uses the RDS roots in the image
  database_environment = [
    { name = "APP_ENV", value = var.environment },
    { name = "AWS_REGION", value = var.region },
    { name = "DB_HOST", value = module.database.address },
    { name = "DB_PORT", value = tostring(module.database.port) },
    { name = "DB_NAME", value = module.database.database_name },
  ]
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name               = local.name
  cidr               = var.vpc_cidr
  azs                = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets     = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets    = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
  enable_nat_gateway = true
  single_nat_gateway = var.environment != "prod"

  # Subnets for the database only, with their own route table and no route to the internet
  database_subnets                   = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, 192 + i)]
  create_database_subnet_group       = false
  create_database_subnet_route_table = true

  # Every accepted and rejected connection in the VPC, kept 30 days in CloudWatch Logs
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = 30
  flow_log_max_aggregation_interval               = 60
}

# PostgreSQL that only the tasks can reach. The service signs in with IAM tokens; the
# migration container signs in as the RDS administrator.
module "database" {
  source = "../modules/aws-database"

  name                      = local.name
  environment               = var.environment
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.database_subnets
  client_security_group_ids = [aws_security_group.task.id]
  instance_class            = var.database_instance_class
  alert_email               = var.alert_email
}

# Phase 1 of a deployment applies only this, so the image can be pushed before the service exists
resource "aws_ecr_repository" "app" {
  name                 = local.name
  image_tag_mutability = "IMMUTABLE"
  # A non-production repository can be deleted with its images, so tofu destroy works
  force_delete = var.environment != "prod"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 30 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecs_cluster" "app" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = 30
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Lets ECS pull the image from ECR and write the container's logs
resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS reads the RDS administrator's password when a task starts and hands it to the migrate
# container only; the app container never sees it, and the task role can't read it
resource "aws_iam_role_policy" "execution_admin_secret" {
  name   = "database-admin-secret"
  role   = aws_iam_role.execution.id
  policy = module.database.admin_secret_policy_json
}

# The containers' own identity: it may only sign in to the database as app_user
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "task_database" {
  name   = "database-connect"
  role   = aws_iam_role.task.id
  policy = module.database.connect_policy_json
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # The containers' root filesystems are read-only; /tmp is the one writable path, as on Kubernetes
  volume {
    name = "tmp"
  }

  # Each task runs the migrations before its app container starts; the advisory lock and
  # Alembic's history make every run after the first a no-op
  container_definitions = jsonencode([
    {
      name      = "migrate"
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = false
      command   = ["python", "-m", "app.migrate"]
      environment = concat(local.database_environment, [
        { name = "DB_AUTH", value = "password" },
        { name = "DB_USER", value = module.database.admin_username },
        { name = "DB_APP_AUTH", value = "aws-iam" },
        { name = "DB_APP_ROLE", value = module.database.app_role },
      ])
      secrets = [
        { name = "DB_PASSWORD", valueFrom = "${module.database.admin_secret_arn}:password::" },
      ]
      readonlyRootFilesystem = true
      mountPoints            = local.tmp_mount
      linuxParameters        = local.no_capabilities
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "migrate"
        }
      }
    },
    {
      name      = "app"
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true
      dependsOn = [{ containerName = "migrate", condition = "SUCCESS" }]
      portMappings = [{
        containerPort = 8000
        protocol      = "tcp"
      }]
      readonlyRootFilesystem = true
      mountPoints            = local.tmp_mount
      linuxParameters        = local.no_capabilities
      environment = concat(local.database_environment, [
        { name = "APP_VERSION", value = var.image_tag },
        { name = "DB_AUTH", value = "aws-iam" },
        { name = "DB_USER", value = module.database.app_role },
      ])
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "app"
        }
      }
    },
  ])
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public HTTP(S) to the load balancer"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group" "task" {
  name        = "${local.name}-task"
  description = "Load balancer traffic to the tasks"
  vpc_id      = module.vpc.vpc_id
}

# The service is public, so the load balancer takes HTTP(S) from anywhere
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count             = local.https ? 1 : 0
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To the tasks"
  referenced_security_group_id = aws_security_group.task.id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "task_database" {
  security_group_id            = aws_security_group.task.id
  description                  = "PostgreSQL"
  referenced_security_group_id = module.database.security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  description                  = "From the load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
}

# Tasks reach ECR and CloudWatch Logs over HTTPS through the NAT gateway
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "task_https" {
  security_group_id = aws_security_group.task.id
  description       = "HTTPS to AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Public on purpose: it fronts a public web service
#trivy:ignore:AWS-0053
resource "aws_lb" "app" {
  name                       = substr(local.name, 0, 32)
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = module.vpc.public_subnets
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  name                 = substr(local.name, 0, 32)
  port                 = 8000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Plain HTTP until certificate_arn is set; with a certificate, port 80 redirects to HTTPS
#trivy:ignore:AWS-0054
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https ? "redirect" : "forward"
    target_group_arn = local.https ? null : aws_lb_target_group.app.arn

    dynamic "redirect" {
      for_each = local.https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = local.https ? 1 : 0
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_ecs_service" "app" {
  name                  = var.service_name
  cluster               = aws_ecs_cluster.app.id
  task_definition       = aws_ecs_task_definition.app.arn
  desired_count         = var.desired_count
  launch_type           = "FARGATE"
  wait_for_steady_state = true

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]
}
