# Database

The service keeps its data in PostgreSQL. On each cloud the database is the managed one
(Amazon RDS, Cloud SQL, Azure Database for PostgreSQL), and the same code connects to all
three. This page covers how the service connects, signs in and migrates its schema, and how
to work with it locally.

## How a request reaches the database

```text
request -> gunicorn worker -> pooled connection ----------------> PostgreSQL
                              |  opened on first use, after fork   (private network, TLS)
                              |  credential fetched per connection
                              |  checked before reuse (pre-ping)
                              '- statement and idle-transaction time limits
```

- **One pool per worker process.** Each gunicorn worker opens its pool on first use, so no
  connection is shared across a fork. A worker never needs more connections than it has
  threads, so the pool keeps two open and allows two more under load (`DB_POOL_SIZE`,
  `DB_MAX_OVERFLOW`). Size the database for
  `replicas x workers x (pool size + overflow)` connections, plus a few for migrations.
- **Every connection is checked before it is handed out**, so one that a failover or an idle
  timeout closed is replaced instead of failing a request.
- **Time limits:** a query is cancelled after 5 seconds (`DB_STATEMENT_TIMEOUT_MS`) and a
  transaction left idle for a minute is closed, so a stuck request can't hold a connection or
  its locks.
- **Failures answer 503 with `Retry-After`,** without details; the reason is logged. A bug in a
  query is still a 500.

## Signing in

`DB_AUTH` picks how the service proves who it is. In the clouds no password exists: the
service asks its platform for a short-lived token each time it opens a connection.

| `DB_AUTH` | Where | The credential |
| --- | --- | --- |
| `aws-iam` | ECS and EKS | An RDS IAM token (valid 15 minutes) that the AWS SDK signs locally with the task's or pod's IAM role |
| `gcp-iam` | Cloud Run and GKE | Cloud SQL IAM database authentication through the Cloud SQL Python Connector, which also sets up TLS with certificates it fetches for the instance |
| `azure-entra` | Container Apps and AKS | A Microsoft Entra token for the workload's managed identity |
| `password` | Locally, in CI, and the AWS migration job | `DB_PASSWORD`, or the `password` field of the Secrets Manager secret in `DB_PASSWORD_SECRET_ARN` |

Connections are encrypted and the server's certificate is checked against its hostname
(`DB_SSLMODE=verify-full`): with the Amazon RDS root certificates shipped in
[app/certs](../app/certs) on AWS, and with the public roots on Azure, whose servers use
publicly trusted certificates. The Cloud SQL connector does its own verification.

## On each platform

| Platform | Database | The service's identity | Migrations run as |
| --- | --- | --- | --- |
| ECS Fargate | Amazon RDS, in database subnets that only the tasks' security group reaches | The task role | A `migrate` container that each task runs before its app container. ECS hands it the RDS administrator's password from Secrets Manager; the app container never sees it |
| Cloud Run | Cloud SQL, private IP only, reached through Direct VPC egress | Its own service account | A Cloud Run job with its own service account, which OpenTofu runs and waits for before it updates the service |
| Container Apps | Azure Database for PostgreSQL flexible server in the environment's virtual network | A user-assigned managed identity | A Container Apps job whose managed identity is the server's Entra administrator; the deploy workflow starts it and waits for it |
| EKS | Amazon RDS, in database subnets with no internet route | IAM role through EKS Pod Identity | A Helm hook Job with its own Pod Identity role, which may only read the RDS administrator's secret |
| GKE | Cloud SQL, private IP only, connector connections only | Google service account through Workload Identity Federation | A Helm hook Job with its own service account (`cloudsqlsuperuser`) |
| AKS | Azure Database for PostgreSQL flexible server, delegated subnet, Entra sign-in only | Managed identity through Microsoft Entra Workload ID | A Helm hook Job whose managed identity is the server's Entra administrator |

The [AWS](aws-architecture.md), [Google Cloud](gcp-architecture.md) and
[Azure](azure-architecture.md) architecture pages describe what OpenTofu creates for each, and
[kubernetes-architecture.md](kubernetes-architecture.md#the-migration-hook) the chart's
migration hook.

## Roles

Two roles touch the database, and the service's role is the weaker one:

| Role | Signs in as | Can |
| --- | --- | --- |
| Administrator (migrations) | AWS: the RDS master user, whose password RDS generates and keeps in Secrets Manager. Google Cloud: a migration service account with the `cloudsqlsuperuser` role. Azure: a migration managed identity that is the server's Entra administrator. | Create roles, own the `app` schema, change tables |
| Service (`DB_APP_ROLE`) | Its own IAM role, service account or managed identity | Read and write rows in the `app` schema; read the migration history |

The service can't create, alter or drop tables, truncate them, or change which migrations
have run. The tests in [tests/test_migrate.py](../tests/test_migrate.py) check each of these.

## Migrations

`python -m app.migrate` brings a database up to date. Every deployment runs it once, before
the new version takes traffic, with the administrator identity:

1. It takes a PostgreSQL advisory lock, so two runs never change the schema at the same time;
   a second run waits, then finds nothing to do.
2. It creates the service's role if it is missing, the way its sign-in method needs: with
   `rds_iam` on RDS, through `pgaadauth_create_principal_with_oid` on Azure, and with a
   password locally. Cloud SQL creates IAM roles itself.
3. It applies the [Alembic](https://alembic.sqlalchemy.org/) migrations in
   [app/migrations/versions](../app/migrations/versions) in one transaction.
4. It grants the service's role read and write access to the tables, and only read access to
   the migration history.

It retries the first connection for a few minutes, because a database or identity created by
the same deployment can take a moment to answer, and it gives up on any table lock it can't
get within 10 seconds rather than queueing the service's queries behind it.

### Writing a migration

```bash
.venv/bin/alembic revision --rev-id 0002 -m "add a description to items"
```

Edit the new file in `app/migrations/versions`, add a test, and run `make test`.

A new version starts while the old one is still serving, so each migration must work with the
code before it as well as after it. Add things first (a nullable column, a new table), ship the
code that uses them, and remove what the old code needed only in a later release.

## The example API

`/api/items` stores short named items, enough to exercise reads, writes and the error paths:

```console
$ curl -s -X POST localhost:8000/api/items -H 'Content-Type: application/json' -d '{"name": "first"}'
{"created_at":"2026-10-11T20:45:25.729481+00:00","id":1,"name":"first"}
$ curl -s localhost:8000/api/items
{"items":[{"created_at":"2026-10-11T20:45:25.729481+00:00","id":1,"name":"first"}]}
$ curl -s localhost:8000/ready
{"database":"ok","service":"enterprise-multi-cloud","status":"ready","version":"local"}
```

It has no authentication of its own. Before it holds real data, put an authenticating proxy or
gateway in front of it (for example ALB authentication, IAP or Container Apps authentication).

## Locally

```bash
make up     # PostgreSQL, the migration job and the service on http://localhost:8000
make test   # starts PostgreSQL if needed; the tests create and drop their own database
make db-down
```

[docker-compose.yml](../docker-compose.yml) wires the three containers the way the clouds do:
the migration job signs in as the administrator, creates `app_user` and exits, then the
service starts and signs in as `app_user`. CI runs the same PostgreSQL for every pull request.

## Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `DB_AUTH` | (none) | `aws-iam`, `gcp-iam`, `azure-entra` or `password`. Without it the service runs without a database. |
| `DB_HOST`, `DB_PORT` | `5432` | The server; not used with `gcp-iam` |
| `DB_INSTANCE` | | `gcp-iam`: the instance connection name, `project:region:instance` |
| `DB_NAME` | `app` | Database name |
| `DB_USER` | | Role to sign in as |
| `DB_PASSWORD`, `DB_PASSWORD_SECRET_ARN` | | `password` only |
| `AWS_REGION` | | `aws-iam`: the database's region (ECS and EKS set it) |
| `DB_SSLMODE` | `verify-full` | libpq's `sslmode`; `disable` only for the local container |
| `DB_SSLROOTCERT` | per cloud | CA certificates that verify the server |
| `DB_POOL_SIZE`, `DB_MAX_OVERFLOW` | `2`, `2` | Connections kept open per worker, and extra ones allowed under load |
| `DB_POOL_TIMEOUT` | `5` | Seconds a request waits for a free connection |
| `DB_POOL_RECYCLE` | `1800` | Seconds before a connection is replaced |
| `DB_CONNECT_TIMEOUT` | `5` | Seconds to open a connection |
| `DB_STATEMENT_TIMEOUT_MS` | `5000` | Longest a query may run |

The migration job also reads:

| Variable | Meaning |
| --- | --- |
| `DB_APP_ROLE` | The role the service signs in as |
| `DB_APP_AUTH` | How that role signs in; defaults to `DB_AUTH` |
| `DB_APP_PASSWORD` | `password` only |
| `DB_APP_PRINCIPAL_ID` | `azure-entra` only: the object ID of the service's managed identity |
| `DB_MAINTENANCE_DATABASE` | Where Azure's role functions live; `postgres` |
| `DB_CONNECT_ATTEMPTS` | First-connection attempts before giving up; `10` |
