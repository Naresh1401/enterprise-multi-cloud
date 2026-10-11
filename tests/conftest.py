"""Shared fixtures.

The PostgreSQL tests need TEST_DATABASE_ADMIN_URL, the URL of a superuser on a test server,
for example docker compose's: postgresql://postgres:local-only-password@127.0.0.1:5432/postgres.
`make test` starts that server and sets the variable; without it those tests are skipped.
"""

import os
import uuid
from dataclasses import dataclass

import pytest
from sqlalchemy import URL, create_engine, text
from sqlalchemy.engine import make_url

from app import db, migrate
from app.main import app as flask_app

ADMIN_URL = os.environ.get("TEST_DATABASE_ADMIN_URL", "")
SUFFIX = uuid.uuid4().hex[:8]


@dataclass(frozen=True)
class Server:
    """A fresh database on the test server, and how to reach it."""

    admin_url: URL
    created_roles: list[str]

    @property
    def host(self) -> str:
        return self.admin_url.host or "127.0.0.1"

    @property
    def port(self) -> int:
        return self.admin_url.port or 5432

    @property
    def database(self) -> str:
        return self.admin_url.database or ""

    def env(self, user: str, password: str, **extra: str) -> dict[str, str]:
        """DB_* settings that sign in with a password, without TLS (the test server has none)."""
        return {
            "DB_AUTH": "password",
            "DB_HOST": self.host,
            "DB_PORT": str(self.port),
            "DB_NAME": self.database,
            "DB_USER": user,
            "DB_PASSWORD": password,
            "DB_SSLMODE": "disable",
            "DB_CONNECT_TIMEOUT": "3",
            **extra,
        }

    def admin_env(self, **extra: str) -> dict[str, str]:
        return self.env(self.admin_url.username or "", self.admin_url.password or "", **extra)

    def role(self, prefix: str) -> str:
        """A role name unique to this test run, dropped when the run ends."""
        name = f"{prefix}_{SUFFIX}"
        self.created_roles.append(name)
        return name

    def execute(self, *statements: str, database: str = "") -> None:
        url = self.admin_url.set(database=database or self.database)
        engine = create_engine(url, isolation_level="AUTOCOMMIT")
        try:
            with engine.connect() as connection:
                cursor = connection.connection.cursor()
                for statement in statements:
                    cursor.execute(statement)
        finally:
            engine.dispose()


@dataclass(frozen=True)
class AppUser:
    """The role the service signs in as, after the migrations ran."""

    name: str
    password: str
    env: dict[str, str]


@pytest.fixture
def client():
    flask_app.config.update(TESTING=True)
    return flask_app.test_client()


@pytest.fixture(autouse=True)
def no_database(monkeypatch):
    """Every test starts without database settings or an open pool."""
    for name in [name for name in os.environ if name.startswith("DB_")]:
        monkeypatch.delenv(name)
    db.reset()
    yield
    db.reset()


@pytest.fixture(scope="session")
def server():
    if not ADMIN_URL:
        pytest.skip("set TEST_DATABASE_ADMIN_URL to run the PostgreSQL tests (make test does)")
    url = make_url(ADMIN_URL).set(drivername="postgresql+psycopg")
    name = f"test_{SUFFIX}"
    admin = create_engine(url, isolation_level="AUTOCOMMIT")
    with admin.connect() as connection:
        connection.exec_driver_sql(f'CREATE DATABASE "{name}"')
    created_roles: list[str] = []
    yield Server(admin_url=url.set(database=name), created_roles=created_roles)
    with admin.connect() as connection:
        connection.exec_driver_sql(f'DROP DATABASE "{name}" WITH (FORCE)')
        for role in created_roles:
            connection.exec_driver_sql(f'DROP ROLE IF EXISTS "{role}"')
    admin.dispose()


@pytest.fixture(scope="session")
def app_user(server):
    """Runs the migrations once, as the administrator, for a password-based service role."""
    name = server.role("app_user")
    password = f"pw-{SUFFIX}"
    env = server.admin_env(DB_APP_ROLE=name, DB_APP_PASSWORD=password)
    assert migrate.main(env=env, sleep=lambda _: None) == 0
    return AppUser(name=name, password=password, env=server.env(name, password))


@pytest.fixture
def connected(app_user, monkeypatch):
    """The service configured to sign in as its own role."""
    for key, value in app_user.env.items():
        monkeypatch.setenv(key, value)
    return app_user


def scalar(server: Server, query: str, user: str = "", password: str = ""):
    """One value, queried as the administrator or as another role."""
    url = server.admin_url
    if user:
        url = url.set(username=user, password=password)
    engine = create_engine(url)
    try:
        with engine.connect() as connection:
            return connection.execute(text(query)).scalar()
    finally:
        engine.dispose()
