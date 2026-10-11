"""Bring the database up to date: ``python -m app.migrate``.

Runs once before a new version of the service takes traffic: as a Helm hook on Kubernetes,
a Cloud Run job, a Container Apps job, or the container that ECS starts ahead of the app.
It signs in with the database's administrator or migration identity (the same DB_* settings
the service uses), then:

1. takes a PostgreSQL advisory lock, so only one run changes the database at a time;
2. makes sure the role the service signs in as (DB_APP_ROLE) exists, created the way its
   sign-in method (DB_APP_AUTH) needs;
3. applies the Alembic migrations in app/migrations;
4. lets that role read and write the tables, and nothing more.

Every step can run again safely, so a retried job or several tasks starting at once are fine.
"""

from __future__ import annotations

import logging
import os
import sys
import time
from collections.abc import Callable, Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from alembic import command
from alembic.config import Config
from alembic.runtime.migration import MigrationContext
from sqlalchemy import Connection, text

from app.db import AUTH_METHODS, SCHEMA, ConfigurationError, Database, Settings

log = logging.getLogger("app.migrate")

MIGRATIONS = Path(__file__).parent / "migrations"
# Any fixed number works, as long as every run of every version uses the same one
LOCK_ID = 2_026_101_101
# A migration may take a while (an index on a big table), but it must not wait long behind
# the service's queries for a table lock: it fails after LOCK_TIMEOUT and the deploy stops
STATEMENT_TIMEOUT_MS = 15 * 60 * 1000
LOCK_TIMEOUT = "10s"


class MigrationError(RuntimeError):
    """The database is not in a state the migration can work with."""


@dataclass(frozen=True)
class AppRole:
    """The role the service signs in as, from the DB_APP_* variables."""

    name: str
    auth: str
    password: str = ""
    principal_id: str = ""

    def __post_init__(self) -> None:
        if not self.name:
            raise ConfigurationError("DB_APP_ROLE must name the role the service signs in as")
        if self.auth not in AUTH_METHODS:
            raise ConfigurationError(
                f"DB_APP_AUTH must be one of {', '.join(AUTH_METHODS)}, not {self.auth!r}"
            )
        if self.auth == "password" and not self.password:
            raise ConfigurationError("DB_APP_AUTH=password needs DB_APP_PASSWORD")
        if self.auth == "azure-entra" and not self.principal_id:
            raise ConfigurationError(
                "DB_APP_AUTH=azure-entra needs DB_APP_PRINCIPAL_ID, the object ID of the "
                "service's managed identity"
            )

    @classmethod
    def from_env(cls, env: Mapping[str, str], default_auth: str) -> AppRole:
        return cls(
            name=env.get("DB_APP_ROLE", "").strip(),
            auth=env.get("DB_APP_AUTH", "").strip() or default_auth,
            password=env.get("DB_APP_PASSWORD", ""),
            principal_id=env.get("DB_APP_PRINCIPAL_ID", "").strip(),
        )


def alembic_config(connection: Connection | None = None) -> Config:
    """Alembic settings for app/migrations; env.py runs the migrations on ``connection``."""
    config = Config()
    config.set_main_option("script_location", str(MIGRATIONS))
    if connection is not None:
        config.attributes["connection"] = connection
    return config


@contextmanager
def _connect(
    database: Database, attempts: int, sleep: Callable[[float], None]
) -> Iterator[Connection]:
    """A connection, retried with backoff: right after a deployment creates the database or
    the identities, the server or the cloud's identity system can take a while to answer."""
    attempt, delay = 1, 1.0
    while True:
        try:
            connection = database.engine.connect()
            break
        except Exception as error:
            if attempt >= attempts:
                raise
            log.warning("Could not connect (attempt %d of %d): %s", attempt, attempts, error)
            sleep(delay)
            attempt, delay = attempt + 1, min(delay * 2, 30)
    with connection:
        yield connection


@contextmanager
def _locked(connection: Connection) -> Iterator[None]:
    log.info("Waiting for the migration lock")
    connection.execute(text("SELECT pg_advisory_lock(:id)"), {"id": LOCK_ID})
    connection.commit()
    try:
        yield
    finally:
        # Ending the session releases the lock too; unlocking keeps that true for a
        # connection that is still open when the run fails
        connection.rollback()
        connection.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": LOCK_ID})
        connection.commit()


def _role_exists(connection: Connection, name: str) -> bool:
    query = text("SELECT 1 FROM pg_roles WHERE rolname = :name")
    return connection.execute(query, {"name": name}).first() is not None


def _run(connection: Connection, statement: str) -> None:
    """Runs a statement built here on the driver's own cursor. Without bind parameters,
    psycopg and pg8000 both send its text as it is, % signs and colons included."""
    cursor = connection.connection.cursor()
    try:
        cursor.execute(statement)
    finally:
        cursor.close()


def _execute_quoted(connection: Connection, template: str, *values: str) -> None:
    """Runs a statement that can't take bind parameters, such as CREATE ROLE, once
    PostgreSQL's format() has quoted the values: %I as an identifier, %L as a literal."""
    names = [f"value{index}" for index in range(len(values))]
    # format() takes its arguments as "any", so each one needs an explicit type
    arguments = ", ".join(f"CAST(:{name} AS text)" for name in names)
    query = text(f"SELECT format(:template, {arguments})")
    parameters = {"template": template, **dict(zip(names, values, strict=True))}
    _run(connection, connection.execute(query, parameters).scalar_one())


def _create_entra_role(
    settings: Settings,
    role: AppRole,
    maintenance_database: str,
    attempts: int,
    sleep: Callable[[float], None],
) -> None:
    """Creates the Microsoft Entra role for the service's managed identity. The pgaadauth
    functions live in the maintenance database (postgres), and roles span every database."""
    database = Database(settings, database=maintenance_database)
    try:
        with _connect(database, attempts, sleep) as connection, _locked(connection):
            if not _role_exists(connection, role.name):
                log.info("Creating the Microsoft Entra role %s", role.name)
                # By object ID, so the server needn't look the identity up in Microsoft Graph
                connection.execute(
                    text(
                        "SELECT * FROM pgaadauth_create_principal_with_oid"
                        "(:name, :object_id, 'service', false, false)"
                    ),
                    {"name": role.name, "object_id": role.principal_id},
                )
                connection.commit()
    finally:
        database.dispose()


def _ensure_role(connection: Connection, role: AppRole) -> None:
    exists = _role_exists(connection, role.name)
    if role.auth == "password":
        verb = "ALTER ROLE %I WITH" if exists else "CREATE ROLE %I"
        _execute_quoted(connection, f"{verb} LOGIN PASSWORD %L", role.name, role.password)
    elif role.auth == "aws-iam":
        if not exists:
            log.info("Creating the role %s", role.name)
            _execute_quoted(connection, "CREATE ROLE %I LOGIN", role.name)
        # Members of rds_iam sign in with IAM tokens, and RDS refuses passwords for them
        _execute_quoted(connection, "GRANT rds_iam TO %I", role.name)
    elif not exists:
        # Cloud SQL creates IAM database users itself, and the Entra role was created first
        raise MigrationError(
            f"Role {role.name} does not exist; it is created with the database "
            "(google_sql_user on Cloud SQL, the Entra role step on Azure)"
        )
    connection.commit()


def _grant(connection: Connection, role: AppRole) -> None:
    """Read and write access to the service's tables: no schema changes, and the migration
    history is read-only."""
    name = connection.dialect.identifier_preparer.quote_identifier(role.name)
    for statement in (
        f"GRANT USAGE ON SCHEMA {SCHEMA} TO {name}",
        f"GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {SCHEMA} TO {name}",
        f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA {SCHEMA} TO {name}",
        # Covers tables that later migrations create, since they run as this same role
        f"ALTER DEFAULT PRIVILEGES IN SCHEMA {SCHEMA}"
        f" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {name}",
        f"ALTER DEFAULT PRIVILEGES IN SCHEMA {SCHEMA} GRANT USAGE, SELECT ON SEQUENCES TO {name}",
        f"REVOKE INSERT, UPDATE, DELETE ON {SCHEMA}.alembic_version FROM {name}",
    ):
        _run(connection, statement)
    connection.commit()


def migrate(
    settings: Settings,
    role: AppRole,
    *,
    maintenance_database: str = "postgres",
    attempts: int = 10,
    sleep: Callable[[float], None] = time.sleep,
) -> str:
    """Runs every step and returns the revision the database is at afterwards."""
    if role.auth == "azure-entra":
        _create_entra_role(settings, role, maintenance_database, attempts, sleep)
    database = Database(settings, statement_timeout_ms=STATEMENT_TIMEOUT_MS)
    try:
        with _connect(database, attempts, sleep) as connection, _locked(connection):
            connection.execute(
                text("SELECT set_config('lock_timeout', :value, false)"), {"value": LOCK_TIMEOUT}
            )
            _ensure_role(connection, role)
            _run(connection, f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")
            connection.commit()
            log.info("Applying migrations")
            command.upgrade(alembic_config(connection), "head")
            connection.commit()
            _grant(connection, role)
            context = MigrationContext.configure(connection, opts={"version_table_schema": SCHEMA})
            revision = context.get_current_revision()
            connection.commit()
    finally:
        database.dispose()
    return revision


def main(env: Mapping[str, str] | None = None, sleep: Callable[[float], None] = time.sleep) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    env = os.environ if env is None else env
    try:
        settings = Settings.from_env(env)
        if settings is None:
            raise ConfigurationError("DB_AUTH is not set, so there is no database to migrate")
        role = AppRole.from_env(env, default_auth=settings.auth)
        attempts = int(env.get("DB_CONNECT_ATTEMPTS", "").strip() or 10)
    except (ConfigurationError, ValueError) as error:
        log.error("%s", error)
        return 2
    try:
        revision = migrate(
            settings,
            role,
            maintenance_database=env.get("DB_MAINTENANCE_DATABASE", "").strip() or "postgres",
            attempts=attempts,
            sleep=sleep,
        )
    except Exception:
        log.exception("Migration failed")
        return 1
    log.info("Database %s is at revision %s; %s can use it", settings.name, revision, role.name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
