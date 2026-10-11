"""PostgreSQL connections, signed in the way each platform prefers.

Settings come from DB_* environment variables, and DB_AUTH picks how the service signs in:

- ``aws-iam``: Amazon RDS IAM authentication. Each new connection uses a 15-minute token
  that the AWS SDK signs locally with the task's or pod's IAM role.
- ``gcp-iam``: Cloud SQL IAM database authentication through the Cloud SQL Python Connector,
  which also encrypts the connection with certificates it fetches for the instance.
- ``azure-entra``: a Microsoft Entra token for the workload's managed identity.
- ``password``: DB_PASSWORD, or the ``password`` field of the AWS Secrets Manager secret in
  DB_PASSWORD_SECRET_ARN. Used locally, in CI, and by the AWS migration job, which signs in
  as the RDS administrator.

A credential is fetched for each new connection and never stored. Without DB_AUTH the service
runs without a database.
"""

from __future__ import annotations

import json
import logging
import os
import threading
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import certifi
from sqlalchemy import Engine, create_engine, event, text
from sqlalchemy.engine import URL

log = logging.getLogger(__name__)

APPLICATION_NAME = "enterprise-multi-cloud"
AUTH_METHODS = ("password", "aws-iam", "gcp-iam", "azure-entra")
# The PostgreSQL schema that holds the service's tables and the migration history
SCHEMA = "app"
# Scope of the Microsoft Entra tokens that Azure Database for PostgreSQL accepts
AZURE_POSTGRES_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"
# Root certificates for every Amazon RDS region, from https://truststore.pki.rds.amazonaws.com
RDS_CA_BUNDLE = Path(__file__).parent / "certs" / "aws-rds-global-bundle.pem"


class ConfigurationError(ValueError):
    """The DB_* settings are missing something or contradict each other."""


class SignInError(RuntimeError):
    """The platform's identity gave no credential, or the Cloud SQL connector could not
    open its encrypted channel to the instance."""


def _number(env: Mapping[str, str], name: str, default: int) -> int:
    raw = env.get(name, "").strip()
    if not raw:
        return default
    if not raw.isdigit():
        raise ConfigurationError(f"{name} must be a whole number, not {raw!r}")
    return int(raw)


@dataclass(frozen=True)
class Settings:
    """Where the database is and how to sign in to it; see the module docstring."""

    auth: str
    user: str
    name: str = "app"
    host: str = ""
    port: int = 5432
    password: str = ""
    password_secret_arn: str = ""
    instance: str = ""
    region: str = ""
    sslmode: str = "verify-full"
    sslrootcert: str = ""
    # Each gunicorn worker serves at most GUNICORN_THREADS requests at once, so it never
    # needs more connections than that: two kept open, two more under load
    pool_size: int = 2
    max_overflow: int = 2
    pool_timeout: int = 5
    pool_recycle: int = 1800
    connect_timeout: int = 5
    statement_timeout_ms: int = 5000

    def __post_init__(self) -> None:
        if self.auth not in AUTH_METHODS:
            raise ConfigurationError(
                f"DB_AUTH must be one of {', '.join(AUTH_METHODS)}, not {self.auth!r}"
            )
        missing = []
        if not self.user:
            missing.append("DB_USER")
        if self.auth == "gcp-iam":
            if not self.instance:
                missing.append("DB_INSTANCE")
        elif not self.host:
            missing.append("DB_HOST")
        if self.auth == "aws-iam" and not self.region:
            missing.append("AWS_REGION")
        if self.auth == "password" and not (self.password or self.password_secret_arn):
            missing.append("DB_PASSWORD or DB_PASSWORD_SECRET_ARN")
        if missing:
            raise ConfigurationError(f"DB_AUTH={self.auth} needs {', '.join(missing)}")
        arn = self.password_secret_arn.split(":")
        valid_arn = len(arn) >= 7 and arn[:3] == ["arn", "aws", "secretsmanager"]
        if self.password_secret_arn and not valid_arn:
            raise ConfigurationError("DB_PASSWORD_SECRET_ARN must be a Secrets Manager secret ARN")

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings | None:
        """Settings from the DB_* variables, or None when DB_AUTH is not set."""
        env = os.environ if env is None else env
        auth = env.get("DB_AUTH", "").strip()
        if not auth:
            return None
        return cls(
            auth=auth,
            user=env.get("DB_USER", "").strip(),
            name=env.get("DB_NAME", "").strip() or "app",
            host=env.get("DB_HOST", "").strip(),
            port=_number(env, "DB_PORT", 5432),
            password=env.get("DB_PASSWORD", ""),
            password_secret_arn=env.get("DB_PASSWORD_SECRET_ARN", "").strip(),
            instance=env.get("DB_INSTANCE", "").strip(),
            region=(env.get("AWS_REGION") or env.get("AWS_DEFAULT_REGION") or "").strip(),
            sslmode=env.get("DB_SSLMODE", "").strip() or "verify-full",
            sslrootcert=env.get("DB_SSLROOTCERT", "").strip(),
            pool_size=_number(env, "DB_POOL_SIZE", 2),
            max_overflow=_number(env, "DB_MAX_OVERFLOW", 2),
            pool_timeout=_number(env, "DB_POOL_TIMEOUT", 5),
            pool_recycle=_number(env, "DB_POOL_RECYCLE", 1800),
            connect_timeout=_number(env, "DB_CONNECT_TIMEOUT", 5),
            statement_timeout_ms=_number(env, "DB_STATEMENT_TIMEOUT_MS", 5000),
        )

    @property
    def root_certificate(self) -> str:
        """The CA certificates that verify the server: DB_SSLROOTCERT if set, Amazon RDS's
        for an RDS server, and otherwise the public roots, which Azure's servers chain to."""
        if self.sslrootcert:
            return self.sslrootcert
        on_rds = ".rds.amazonaws.com" in self.host
        if self.auth == "aws-iam" or self.password_secret_arn or on_rds:
            return str(RDS_CA_BUNDLE)
        return certifi.where()


def credential_source(settings: Settings) -> Callable[[], str]:
    """A function that returns the password for the next connection."""
    if settings.auth == "aws-iam":
        import boto3

        rds = boto3.client("rds", region_name=settings.region)
        return lambda: rds.generate_db_auth_token(
            DBHostname=settings.host, Port=settings.port, DBUsername=settings.user
        )
    if settings.auth == "azure-entra":
        from azure.identity import DefaultAzureCredential

        # Workload identity on AKS, the user-assigned identity in AZURE_CLIENT_ID on Container Apps
        credential = DefaultAzureCredential()
        return lambda: credential.get_token(AZURE_POSTGRES_SCOPE).token
    if settings.password_secret_arn:
        import boto3

        # arn:aws:secretsmanager:<region>:<account>:secret:<name>
        region = settings.password_secret_arn.split(":")[3]
        secrets = boto3.client("secretsmanager", region_name=region)

        def from_secret() -> str:
            # Read on every connection, so a rotated password is picked up without a restart
            secret = secrets.get_secret_value(SecretId=settings.password_secret_arn)
            return json.loads(secret["SecretString"])["password"]

        return from_secret
    return lambda: settings.password


def _session_limits(statement_timeout_ms: int) -> Callable[[Any, Any], None]:
    """Limits every new connection, so a stuck query or an abandoned transaction can't hold
    a connection, or the locks it took, indefinitely."""

    def apply(dbapi_connection: Any, _record: Any) -> None:
        cursor = dbapi_connection.cursor()
        try:
            cursor.execute(
                "SELECT set_config('statement_timeout', %s, false)", (str(statement_timeout_ms),)
            )
            cursor.execute(
                "SELECT set_config('idle_in_transaction_session_timeout', '60000', false)"
            )
        finally:
            cursor.close()
        # Settings made inside a transaction that is rolled back would be undone
        dbapi_connection.commit()

    return apply


class Database:
    """A pool of connections for one set of settings."""

    def __init__(
        self, settings: Settings, *, database: str = "", statement_timeout_ms: int | None = None
    ) -> None:
        self.settings = settings
        self._connector: Any = None
        pool = {
            "pool_size": settings.pool_size,
            "max_overflow": settings.max_overflow,
            "pool_timeout": settings.pool_timeout,
            "pool_recycle": settings.pool_recycle,
            # Replaces a connection that a failover or an idle timeout closed, instead of
            # failing the request that gets it
            "pool_pre_ping": True,
        }
        name = database or settings.name
        if settings.auth == "gcp-iam":
            self.engine = self._cloud_sql_engine(name, pool)
        else:
            self.engine = self._psycopg_engine(name, pool)
        if statement_timeout_ms is None:
            statement_timeout_ms = settings.statement_timeout_ms
        event.listen(self.engine, "connect", _session_limits(statement_timeout_ms))

    def _psycopg_engine(self, name: str, pool: dict[str, Any]) -> Engine:
        settings = self.settings
        url = URL.create(
            "postgresql+psycopg",
            username=settings.user,
            host=settings.host,
            port=settings.port,
            database=name,
        )
        connect_args: dict[str, Any] = {
            "sslmode": settings.sslmode,
            "connect_timeout": settings.connect_timeout,
            "application_name": APPLICATION_NAME,
        }
        if settings.sslmode != "disable":
            connect_args["sslrootcert"] = settings.root_certificate
        engine = create_engine(url, connect_args=connect_args, **pool)
        password = credential_source(settings)

        @event.listens_for(engine, "do_connect")
        def sign_in(_dialect: Any, _record: Any, _cargs: Any, cparams: dict[str, Any]) -> None:
            try:
                cparams["password"] = password()
            except Exception as error:
                raise SignInError(
                    f"could not get a {settings.auth} credential for {settings.user}"
                ) from error

        return engine

    def _cloud_sql_engine(self, name: str, pool: dict[str, Any]) -> Engine:
        import pg8000.dbapi
        from google.cloud.sql.connector import Connector, IPTypes

        settings = self.settings
        # The lazy strategy fetches the instance's certificates when a connection opens rather
        # than refreshing them in the background, which Cloud Run's CPU throttling would stall
        connector = Connector(
            ip_type=IPTypes.PRIVATE,
            enable_iam_auth=True,
            timeout=settings.connect_timeout,
            refresh_strategy="lazy",
        )
        self._connector = connector

        def connect() -> Any:
            try:
                return connector.connect(
                    settings.instance,
                    "pg8000",
                    user=settings.user,
                    db=name,
                    application_name=APPLICATION_NAME,
                )
            except pg8000.dbapi.Error:
                # PostgreSQL's own answer, which SQLAlchemy reports like any other driver's
                raise
            except Exception as error:
                raise SignInError(
                    f"could not open a Cloud SQL connection to {settings.instance}"
                ) from error

        return create_engine("postgresql+pg8000://", creator=connect, **pool)

    def dispose(self) -> None:
        """Closes every connection, and the Cloud SQL connector if there is one."""
        self.engine.dispose()
        if self._connector is not None:
            self._connector.close()


_database: Database | None = None
_lock = threading.Lock()


def get_database() -> Database | None:
    """This process's pool, or None without DB_AUTH. It is created on first use, which is
    after gunicorn has forked its workers, so no connection is shared between processes."""
    global _database
    with _lock:
        if _database is None:
            settings = Settings.from_env()
            if settings is None:
                return None
            _database = Database(settings)
        return _database


def reset() -> None:
    """Closes the pool; the next use opens a new one with the settings at that time."""
    global _database
    with _lock:
        if _database is not None:
            _database.dispose()
            _database = None


def ping() -> str:
    """'ok' once a query succeeds, 'not configured' without DB_AUTH; raises otherwise."""
    database = get_database()
    if database is None:
        return "not configured"
    with database.engine.connect() as connection:
        connection.execute(text("SELECT 1"))
    return "ok"
