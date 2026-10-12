# Checks the RDS settings the architecture relies on, planned against a mock AWS provider
# (no AWS account needed): `tofu init -backend=false && tofu test`
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      resource_id = "db-ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:111122223333:secret:rds!db-mock"
        kms_key_id    = "arn:aws:kms:us-east-1:111122223333:key/mock"
        secret_status = "active"
      }]
    }
  }
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:111122223333:mock-database-alerts"
    }
  }
}

variables {
  name                      = "multi-cloud-dev"
  environment               = "dev"
  vpc_id                    = "vpc-0123456789abcdef0"
  subnet_ids                = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
  client_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
  client_cidr_blocks        = ["10.30.128.0/20", "10.30.144.0/20"]
}

run "dev" {
  command = plan

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "The database must have no public endpoint."
  }
  assert {
    condition     = aws_db_instance.this.storage_encrypted && aws_db_instance.this.storage_type == "gp3"
    error_message = "Storage must be encrypted gp3."
  }
  assert {
    condition     = aws_db_instance.this.engine == "postgres" && aws_db_instance.this.engine_version == "17"
    error_message = "The database must run PostgreSQL 17, like the other clouds."
  }
  assert {
    condition     = aws_db_instance.this.iam_database_authentication_enabled
    error_message = "IAM database authentication must be on: the service signs in with IAM tokens."
  }
  assert {
    condition     = aws_db_instance.this.manage_master_user_password && aws_db_instance.this.username == "dbadmin"
    error_message = "RDS must generate the administrator password and keep it in Secrets Manager."
  }
  assert {
    condition     = aws_db_instance.this.ca_cert_identifier == "rds-ca-rsa2048-g1"
    error_message = "The server certificate must come from the CA in app/certs/aws-rds-global-bundle.pem."
  }
  assert {
    condition     = contains([for p in aws_db_parameter_group.this.parameter : "${p.name}=${p.value}"], "rds.force_ssl=1")
    error_message = "The server must refuse connections without TLS (rds.force_ssl=1)."
  }
  assert {
    condition = alltrue([
      for p in ["log_connections=1", "log_disconnections=1"] :
      contains([for q in aws_db_parameter_group.this.parameter : "${q.name}=${q.value}"], p)
    ])
    error_message = "Connections and disconnections must be logged."
  }
  assert {
    condition     = aws_db_parameter_group.this.family == "postgres17"
    error_message = "The parameter group must match the engine's major version."
  }
  assert {
    condition = (
      !aws_db_instance.this.multi_az && aws_db_instance.this.backup_retention_period == 7 &&
      !aws_db_instance.this.deletion_protection && aws_db_instance.this.skip_final_snapshot &&
      aws_db_instance.this.apply_immediately
    )
    error_message = "dev runs in one zone with 7 days of backups and can be destroyed without a snapshot."
  }
  assert {
    condition     = aws_db_subnet_group.this.subnet_ids == toset(var.subnet_ids)
    error_message = "The database must live in the given private subnets."
  }
  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.from_security_groups) == 1 &&
      length(aws_vpc_security_group_ingress_rule.from_cidrs) == 2 &&
      alltrue([
        for rule in concat(aws_vpc_security_group_ingress_rule.from_security_groups, aws_vpc_security_group_ingress_rule.from_cidrs) :
        rule.from_port == 5432 && rule.to_port == 5432 && rule.ip_protocol == "tcp"
      ])
    )
    error_message = "Only PostgreSQL (5432) from the given security groups and address ranges may come in."
  }
  assert {
    condition     = one(data.aws_iam_policy_document.connect.statement).actions == toset(["rds-db:connect"])
    error_message = "The service's policy may only connect to the database."
  }
  assert {
    condition     = one(one(data.aws_iam_policy_document.connect.statement).resources) == "arn:aws:rds-db:us-east-1:111122223333:dbuser:db-ABCDEFGHIJKLMNOPQRSTUVWXYZ/app_user"
    error_message = "The service may only sign in as app_user on this instance."
  }
  assert {
    condition     = one(data.aws_iam_policy_document.admin_secret.statement).actions == toset(["secretsmanager:GetSecretValue"])
    error_message = "The migration identity may only read the administrator's secret."
  }
  assert {
    condition     = output.admin_secret_arn == "arn:aws:secretsmanager:us-east-1:111122223333:secret:rds!db-mock"
    error_message = "The module must output the secret RDS keeps the administrator password in."
  }
  assert {
    condition     = length(aws_sns_topic.alerts) == 0 && output.alarm_topic_arn == null
    error_message = "Without alert_email, no SNS topic must exist and the alarms must have no actions."
  }
  assert {
    condition = (
      length(aws_cloudwatch_metric_alarm.cpu.alarm_actions) == 0 &&
      length(aws_cloudwatch_metric_alarm.storage.alarm_actions) == 0 &&
      length(aws_cloudwatch_metric_alarm.connections.alarm_actions) == 0
    )
    error_message = "Without alert_email, the alarms must have no actions."
  }
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.cpu.namespace == "AWS/RDS" && aws_cloudwatch_metric_alarm.cpu.metric_name == "CPUUtilization" &&
      aws_cloudwatch_metric_alarm.storage.metric_name == "FreeStorageSpace" &&
      aws_cloudwatch_metric_alarm.connections.metric_name == "DatabaseConnections"
    )
    error_message = "CPU, storage and connections must each have their own RDS alarm."
  }
}

run "with_alerts" {
  command = plan

  variables {
    alert_email = "ops@example.com"
  }

  assert {
    condition = (
      length(aws_sns_topic.alerts) == 1 &&
      aws_sns_topic_subscription.alerts_email[0].protocol == "email" &&
      aws_sns_topic_subscription.alerts_email[0].endpoint == "ops@example.com"
    )
    error_message = "alert_email must create an SNS topic with an email subscription."
  }
  assert {
    condition     = contains(aws_cloudwatch_metric_alarm.cpu.alarm_actions, aws_sns_topic.alerts[0].arn)
    error_message = "The alarms must notify the SNS topic when alert_email is set."
  }
  assert {
    condition     = length(aws_db_event_subscription.failover) == 0
    error_message = "dev has no standby, so it gets no failover subscription even with alert_email."
  }
}

run "prod" {
  command = plan

  variables {
    name        = "multi-cloud-prod"
    environment = "prod"
    alert_email = "ops@example.com"
  }

  assert {
    condition     = aws_db_instance.this.multi_az && aws_db_instance.this.backup_retention_period == 14
    error_message = "prod must run Multi-AZ with 14 days of backups."
  }
  assert {
    condition = (
      length(aws_db_event_subscription.failover) == 1 &&
      aws_db_event_subscription.failover[0].event_categories == toset(["failover"])
    )
    error_message = "prod with alert_email must subscribe to the database's failover events."
  }
  assert {
    condition = (
      aws_db_instance.this.deletion_protection && !aws_db_instance.this.skip_final_snapshot &&
      aws_db_instance.this.final_snapshot_identifier == "multi-cloud-prod-final" &&
      !aws_db_instance.this.apply_immediately
    )
    error_message = "prod must be protected from deletion, keep a final snapshot and apply changes in the maintenance window."
  }
}

run "customer_managed_key" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/mock"
  }

  assert {
    condition = (
      aws_db_instance.this.kms_key_id == "arn:aws:kms:us-east-1:111122223333:key/mock" &&
      aws_db_instance.this.performance_insights_kms_key_id == "arn:aws:kms:us-east-1:111122223333:key/mock"
    )
    error_message = "kms_key_arn must encrypt both storage and Performance Insights."
  }
}

run "provisioned_storage_performance" {
  command = plan

  variables {
    storage_iops       = 6000
    storage_throughput = 250
  }

  assert {
    condition     = aws_db_instance.this.iops == 6000 && aws_db_instance.this.storage_throughput == 250
    error_message = "storage_iops and storage_throughput must provision gp3 above its free baseline."
  }
}
