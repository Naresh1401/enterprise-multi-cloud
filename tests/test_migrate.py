import threading

import pytest
from alembic import command
from sqlalchemy.exc import OperationalError, ProgrammingError

from app import migrate
from app.db import Database, Settings
from app.migrate import AppRole
from tests.conftest import scalar


def test_the_service_role_can_use_the_tables(server, app_user):
    count = scalar(server, "SELECT count(*) FROM app.items", app_user.name, app_user.password)
    assert count >= 0
    revision = scalar(
        server, "SELECT version_num FROM app.alembic_version", app_user.name, app_user.password
    )
    assert revision == "0001"


@pytest.mark.parametrize(
    "statement",
    [
        "CREATE TABLE app.scratch (id int)",
        "DROP TABLE app.items",
        "ALTER TABLE app.items ADD COLUMN extra text",
        "DELETE FROM app.alembic_version",
        "UPDATE app.alembic_version SET version_num = 'x'",
        "TRUNCATE app.items",
    ],
)
def test_the_service_role_cannot_change_the_schema(server, app_user, statement):
    with pytest.raises(ProgrammingError, match="permission denied|must be owner"):
        scalar(server, statement, app_user.name, app_user.password)


def test_running_again_changes_nothing(server, app_user):
    env = server.admin_env(DB_APP_ROLE=app_user.name, DB_APP_PASSWORD=app_user.password)
    assert migrate.main(env=env, sleep=lambda _: None) == 0
    assert scalar(server, "SELECT version_num FROM app.alembic_version") == "0001"


def test_concurrent_runs_take_turns(server, app_user):
    settings = Settings.from_env(server.admin_env())
    role = AppRole(name=app_user.name, auth="password", password=app_user.password)
    results, errors = [], []

    def run():
        try:
            results.append(migrate.migrate(settings, role, sleep=lambda _: None))
        except Exception as error:  # pragma: no cover - reported by the assertion below
            errors.append(error)

    threads = [threading.Thread(target=run) for _ in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert errors == []
    assert results == ["0001"] * 4


def test_iam_role_on_rds(server):
    # rds_iam only exists on RDS; an empty stand-in lets the grant run here
    server.execute(
        "DO $$ BEGIN CREATE ROLE rds_iam; EXCEPTION WHEN duplicate_object THEN NULL; END $$"
    )
    name = server.role("rds_app")
    settings = Settings.from_env(server.admin_env())
    for _ in range(2):
        assert migrate.migrate(settings, AppRole(name=name, auth="aws-iam")) == "0001"
    member = scalar(server, f"SELECT pg_has_role('{name}', 'rds_iam', 'MEMBER')")
    assert member is True
    assert scalar(server, f"SELECT has_table_privilege('{name}', 'app.items', 'INSERT')") is True


def test_entra_role_on_azure(server):
    # The Azure server's pgaadauth function, reduced to the role it creates
    server.execute(
        """
        CREATE OR REPLACE FUNCTION pgaadauth_create_principal_with_oid(
            role_name text, object_id text, object_type text, is_admin boolean, is_mfa boolean
        ) RETURNS text LANGUAGE plpgsql AS $$
        BEGIN
            IF object_type <> 'service' OR is_admin OR is_mfa THEN
                RAISE EXCEPTION 'unexpected arguments';
            END IF;
            EXECUTE format('CREATE ROLE %I LOGIN', role_name);
            EXECUTE format('COMMENT ON ROLE %I IS %L', role_name, object_id);
            RETURN 'Created role for ' || role_name;
        END $$
        """
    )
    name = server.role("entra_app")
    settings = Settings.from_env(server.admin_env())
    role = AppRole(name=name, auth="azure-entra", principal_id="0f1e2d3c-object-id")
    for _ in range(2):
        revision = migrate.migrate(settings, role, maintenance_database=server.database)
        assert revision == "0001"
    comment = scalar(server, f"SELECT shobj_description('\"{name}\"'::regrole, 'pg_authid')")
    assert comment == "0f1e2d3c-object-id"
    assert scalar(server, f"SELECT has_table_privilege('{name}', 'app.items', 'SELECT')") is True


def test_cloud_sql_iam_role_must_already_exist(server):
    settings = Settings.from_env(server.admin_env())
    role = AppRole(name=server.role("missing_iam"), auth="gcp-iam")
    with pytest.raises(migrate.MigrationError, match="google_sql_user on Cloud SQL"):
        migrate.migrate(settings, role)


def test_cloud_sql_iam_role_gets_grants(server):
    name = server.role("app-runtime@project.iam")
    server.execute(f'CREATE ROLE "{name}" LOGIN')
    settings = Settings.from_env(server.admin_env())
    assert migrate.migrate(settings, AppRole(name=name, auth="gcp-iam")) == "0001"
    query = f"SELECT has_table_privilege('{name}', 'app.items', 'UPDATE')"
    assert scalar(server, query) is True


def test_migrations_downgrade_and_upgrade(server, app_user):
    database = Database(Settings.from_env(server.admin_env()))
    try:
        with database.engine.connect() as connection:
            command.downgrade(migrate.alembic_config(connection), "base")
            connection.commit()
            assert scalar(server, "SELECT to_regclass('app.items')") is None
            command.upgrade(migrate.alembic_config(connection), "head")
            connection.commit()
    finally:
        database.dispose()
    # The new table needs its grants again, which a normal run always applies
    env = server.admin_env(DB_APP_ROLE=app_user.name, DB_APP_PASSWORD=app_user.password)
    assert migrate.main(env=env, sleep=lambda _: None) == 0
    assert scalar(server, "SELECT count(*) FROM app.items", app_user.name, app_user.password) == 0


def test_alembic_needs_the_migration_connection():
    with pytest.raises(RuntimeError, match="python -m app.migrate"):
        command.upgrade(migrate.alembic_config(), "head")


def test_connecting_is_retried(server, monkeypatch):
    settings = Settings.from_env(server.admin_env())
    database = Database(settings)
    real_connect = database.engine.connect
    failures = iter([OperationalError("connect", {}, Exception("starting up"))] * 3)

    def flaky_connect():
        failure = next(failures, None)
        if failure is not None:
            raise failure
        return real_connect()

    monkeypatch.setattr(database.engine, "connect", flaky_connect)
    sleeps = []
    try:
        with migrate._connect(database, attempts=5, sleep=sleeps.append) as connection:
            assert connection.exec_driver_sql("SELECT 1").scalar() == 1
    finally:
        database.dispose()
    assert sleeps == [1.0, 2.0, 4.0]


def test_connecting_gives_up(monkeypatch):
    settings = Settings(auth="password", user="u", host="127.0.0.1", port=1, password="x")
    database = Database(settings)
    sleeps = []
    try:
        with (
            pytest.raises(OperationalError),
            migrate._connect(database, attempts=7, sleep=sleeps.append),
        ):
            pass  # pragma: no cover - the connection never opens
    finally:
        database.dispose()
    assert sleeps == [1.0, 2.0, 4.0, 8.0, 16.0, 30.0]


def test_main_without_settings(caplog):
    assert migrate.main(env={}) == 2
    assert "DB_AUTH is not set" in caplog.text


@pytest.mark.parametrize(
    ("values", "message"),
    [
        ({}, "DB_APP_ROLE must name the role"),
        ({"DB_APP_ROLE": "r", "DB_APP_AUTH": "ldap"}, "DB_APP_AUTH must be one of"),
        ({"DB_APP_ROLE": "r"}, "DB_APP_AUTH=password needs DB_APP_PASSWORD"),
        ({"DB_APP_ROLE": "r", "DB_APP_AUTH": "azure-entra"}, "needs DB_APP_PRINCIPAL_ID"),
        ({"DB_APP_ROLE": "r", "DB_APP_AUTH": "aws-iam", "DB_CONNECT_ATTEMPTS": "x"}, "int"),
    ],
)
def test_main_checks_the_service_role(values, message, caplog):
    env = {"DB_AUTH": "password", "DB_HOST": "h", "DB_USER": "u", "DB_PASSWORD": "p", **values}
    assert migrate.main(env=env) == 2
    assert message in caplog.text


def test_main_reports_a_failed_migration(caplog):
    env = {
        "DB_AUTH": "password",
        "DB_HOST": "127.0.0.1",
        "DB_PORT": "1",
        "DB_USER": "u",
        "DB_PASSWORD": "p",
        "DB_SSLMODE": "disable",
        "DB_APP_ROLE": "r",
        "DB_APP_AUTH": "aws-iam",
        "DB_CONNECT_ATTEMPTS": "1",
    }
    assert migrate.main(env=env) == 1
    assert "Migration failed" in caplog.text
