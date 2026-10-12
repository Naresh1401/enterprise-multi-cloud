# Plans this folder against a mock AWS provider, so `tofu test` works without an AWS account.
# The mocks give computed attributes realistic values where the provider checks their format.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/mock/0123456789abcdef"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/mock/0123456789abcdef"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:111122223333:log-group:mock"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::111122223333:policy/mock"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/mock"
    }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:111122223333:secret:rds!db-mock"
        kms_key_id    = "arn:aws:kms:us-east-1:111122223333:key/mock"
        secret_status = "active"
      }]
    }
  }
}

variables {
  environment = "dev"
  image_tag   = "0123456789abcdef0123456789abcdef01234567"
}

run "dev" {
  command = plan

  assert {
    condition     = aws_ecs_service.app.launch_type == "FARGATE" && !aws_ecs_service.app.network_configuration[0].assign_public_ip
    error_message = "Tasks must run on Fargate without public IP addresses."
  }
  assert {
    condition = (
      aws_ecs_service.app.wait_for_steady_state &&
      aws_ecs_service.app.deployment_circuit_breaker[0].enable &&
      aws_ecs_service.app.deployment_circuit_breaker[0].rollback
    )
    error_message = "A deployment must wait for steady tasks and roll back by itself when they fail."
  }
  assert {
    condition     = [for c in jsondecode(aws_ecs_task_definition.app.container_definitions) : c.name] == ["migrate", "app"]
    error_message = "Each task must run a migrate container and the app container."
  }
  assert {
    condition = (
      !jsondecode(aws_ecs_task_definition.app.container_definitions)[0].essential &&
      jsondecode(aws_ecs_task_definition.app.container_definitions)[0].command == ["python", "-m", "app.migrate"]
    )
    error_message = "The migrate container runs python -m app.migrate and may exit."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.app.container_definitions)[1].dependsOn == [{ containerName = "migrate", condition = "SUCCESS" }]
    error_message = "The app container must start only after the migrations succeeded."
  }
  assert {
    condition = (
      [for secret in jsondecode(aws_ecs_task_definition.app.container_definitions)[0].secrets : secret.name] == ["DB_PASSWORD"] &&
      !can(jsondecode(aws_ecs_task_definition.app.container_definitions)[1].secrets)
    )
    error_message = "Only the migrate container may receive the RDS administrator's password."
  }
  assert {
    condition = alltrue([
      for pair in ["DB_AUTH=aws-iam", "DB_USER=app_user", "AWS_REGION=us-east-1"] :
      contains([for e in jsondecode(aws_ecs_task_definition.app.container_definitions)[1].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "The app container must sign in as app_user with RDS IAM tokens."
  }
  assert {
    condition = alltrue([
      for pair in ["DB_AUTH=password", "DB_USER=dbadmin", "DB_APP_AUTH=aws-iam", "DB_APP_ROLE=app_user"] :
      contains([for e in jsondecode(aws_ecs_task_definition.app.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "The migrate container must sign in as the administrator and create app_user for IAM sign-in."
  }
  assert {
    condition = alltrue([
      for c in jsondecode(aws_ecs_task_definition.app.container_definitions) :
      c.readonlyRootFilesystem && c.linuxParameters.capabilities.drop == ["ALL"] && c.mountPoints[0].containerPath == "/tmp"
    ])
    error_message = "Both containers must run with a read-only root filesystem, no Linux capabilities and only /tmp writable."
  }
  assert {
    condition     = aws_iam_role.task.name == "multi-cloud-app-dev-task" && aws_iam_role.execution.name == "multi-cloud-app-dev-execution"
    error_message = "The tasks and ECS itself must use separate roles."
  }
  assert {
    condition     = !aws_lb.app.internal && aws_lb.app.load_balancer_type == "application" && aws_lb.app.drop_invalid_header_fields
    error_message = "The load balancer must be public, application-level and drop invalid headers."
  }
  assert {
    condition = (
      aws_lb_target_group.app.target_type == "ip" && aws_lb_target_group.app.port == 8000 &&
      aws_lb_target_group.app.health_check[0].path == "/health"
    )
    error_message = "The load balancer must send traffic to the tasks' port 8000 and check /health."
  }
  assert {
    condition     = length(aws_lb_listener.https) == 0 && aws_lb_listener.http.default_action[0].type == "forward"
    error_message = "Without a certificate, port 80 must serve the app."
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.task_from_alb.from_port == 8000 &&
      aws_vpc_security_group_egress_rule.task_database.from_port == 5432 &&
      aws_vpc_security_group_egress_rule.task_https.from_port == 443
    )
    error_message = "Tasks take 8000 from the load balancer and may only reach the database and HTTPS."
  }
  assert {
    condition = (
      aws_ecr_repository.app.image_tag_mutability == "IMMUTABLE" &&
      aws_ecr_repository.app.image_scanning_configuration[0].scan_on_push &&
      aws_ecr_repository.app.encryption_configuration[0].encryption_type == "KMS" &&
      aws_ecr_repository.app.force_delete
    )
    error_message = "Images must be immutable, scanned on push and KMS-encrypted; dev's repository can be deleted."
  }
  assert {
    condition     = aws_cloudwatch_log_group.app.name == "/ecs/multi-cloud-app-dev" && aws_cloudwatch_log_group.app.retention_in_days == 30
    error_message = "Container logs must go to /ecs/<service>-<environment> for 30 days."
  }
  assert {
    condition     = aws_ecs_cluster.app.setting == toset([{ name = "containerInsights", value = "enabled" }])
    error_message = "Container Insights must be on."
  }
}

run "https" {
  command = plan

  variables {
    certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/mock"
  }

  assert {
    condition = (
      length(aws_lb_listener.https) == 1 &&
      aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06" &&
      length(aws_vpc_security_group_ingress_rule.alb_https) == 1
    )
    error_message = "With a certificate, the load balancer must serve HTTPS with TLS 1.2 or 1.3."
  }
  assert {
    condition = (
      aws_lb_listener.http.default_action[0].type == "redirect" &&
      aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS" &&
      aws_lb_listener.http.default_action[0].redirect[0].status_code == "HTTP_301"
    )
    error_message = "With a certificate, port 80 must redirect to HTTPS."
  }
}

run "prod" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = !aws_ecr_repository.app.force_delete
    error_message = "prod's repository must keep its images."
  }
}
