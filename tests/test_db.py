import json

import pg8000.dbapi
import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from app import db
from app.db import ConfigurationError, Database, Settings, SignInError, credential_source
from tests.conftest import scalar


def env(**values: str) -> dict[str, str]:
    return {"DB_AUTH": "password", "DB_HOST": "db.internal", "DB_USER": "app", **values}


def test_no_settings_without_db_auth():
    assert Settings.from_env({}) is None
    assert Settings.from_env({"DB_AUTH": "  ", "DB_HOST": "db.internal"}) is None


def test_settings_defaults():
    settings = Settings.from_env(env(DB_PASSWORD="secret"))
    assert settings == Settings(auth="password", user="app", host="db.internal", password="secret")
    assert settings.name == "app"
    assert settings.port == 5432
    assert settings.sslmode == "verify-full"
    assert (settings.pool_size, settings.max_overflow) == (2, 2)
    assert settings.statement_timeout_ms == 5000


def test_settings_from_every_variable():
    settings = Settings.from_env(
        {
            "DB_AUTH": "aws-iam",
            "DB_HOST": "app.abc123.us-east-1.rds.amazonaws.com",
            "DB_PORT": "6432",
            "DB_NAME": "orders",
            "DB_USER": "app_user",
            "AWS_DEFAULT_REGION": "us-east-1",
            "DB_SSLMODE": "verify-ca",
            "DB_SSLROOTCERT": "/certs/ca.pem",
            "DB_POOL_SIZE": "4",
            "DB_MAX_OVERFLOW": "0",
            "DB_POOL_TIMEOUT": "2",
            "DB_POOL_RECYCLE": "600",
            "DB_CONNECT_TIMEOUT": "9",
            "DB_STATEMENT_TIMEOUT_MS": "250",
        }
    )
    assert settings == Settings(
        auth="aws-iam",
        user="app_user",
        name="orders",
        host="app.abc123.us-east-1.rds.amazonaws.com",
        port=6432,
        region="us-east-1",
        sslmode="verify-ca",
        sslrootcert="/certs/ca.pem",
        pool_size=4,
        max_overflow=0,
        pool_timeout=2,
        pool_recycle=600,
        connect_timeout=9,
        statement_timeout_ms=250,
    )


def test_aws_region_wins_over_the_default_region():
    settings = Settings.from_env(
        env(DB_AUTH="aws-iam", AWS_REGION="eu-west-1", AWS_DEFAULT_REGION="us-east-1")
    )
    assert settings.region == "eu-west-1"


def test_unknown_sign_in_method_is_refused():
    with pytest.raises(ConfigurationError, match="DB_AUTH must be one of"):
        Settings.from_env(env(DB_AUTH="kerberos"))


@pytest.mark.parametrize(
    ("values", "missing"),
    [
        ({"DB_AUTH": "password"}, "DB_USER, DB_HOST, DB_PASSWORD or DB_PASSWORD_SECRET_ARN"),
        ({"DB_AUTH": "aws-iam", "DB_HOST": "h", "DB_USER": "u"}, "AWS_REGION"),
        ({"DB_AUTH": "gcp-iam", "DB_HOST": "h", "DB_USER": "u"}, "DB_INSTANCE"),
        ({"DB_AUTH": "azure-entra", "DB_USER": "u"}, "DB_HOST"),
    ],
)
def test_missing_settings_are_named(values, missing):
    with pytest.raises(ConfigurationError, match=f"needs {missing}$"):
        Settings.from_env(values)


def test_numbers_are_checked():
    with pytest.raises(ConfigurationError, match="DB_PORT must be a whole number, not 'five'"):
        Settings.from_env(env(DB_PASSWORD="x", DB_PORT="five"))


def test_secret_arn_must_be_a_secrets_manager_arn():
    with pytest.raises(ConfigurationError, match="Secrets Manager secret ARN"):
        Settings.from_env(env(DB_PASSWORD_SECRET_ARN="arn:aws:s3:::bucket"))


def test_root_certificates():
    rds = Settings(auth="aws-iam", user="u", host="h", region="us-east-1")
    assert rds.root_certificate == str(db.RDS_CA_BUNDLE)
    assert "BEGIN CERTIFICATE" in db.RDS_CA_BUNDLE.read_text()
    secret = Settings(
        auth="password",
        user="u",
        host="h",
        password_secret_arn="arn:aws:secretsmanager:us-east-1:111122223333:secret:rds!db-1",
    )
    assert secret.root_certificate == str(db.RDS_CA_BUNDLE)
    admin = Settings(
        auth="password", user="dbadmin", host="db.abc123.eu-west-1.rds.amazonaws.com", password="p"
    )
    assert admin.root_certificate == str(db.RDS_CA_BUNDLE)
    azure = Settings(auth="azure-entra", user="u", host="h")
    assert azure.root_certificate.endswith("cacert.pem")
    custom = Settings(auth="azure-entra", user="u", host="h", sslrootcert="/etc/ca.pem")
    assert custom.root_certificate == "/etc/ca.pem"


def test_password_credential():
    password = credential_source(Settings(auth="password", user="u", host="h", password="pw"))
    assert password() == "pw"


class FakeAwsClient:
    def __init__(self, service, region_name):
        self.service = service
        self.region = region_name
        self.calls = []

    def generate_db_auth_token(self, **kwargs):
        self.calls.append(kwargs)
        return f"token-{len(self.calls)}"

    def get_secret_value(self, SecretId):  # noqa: N803 (boto3's parameter name)
        self.calls.append(SecretId)
        return {"SecretString": json.dumps({"username": "dbadmin", "password": "rotated"})}


@pytest.fixture
def aws_clients(monkeypatch):
    import boto3

    clients = []

    def client(service, region_name):
        clients.append(FakeAwsClient(service, region_name))
        return clients[-1]

    monkeypatch.setattr(boto3, "client", client)
    return clients


def test_rds_iam_token_for_each_connection(aws_clients):
    settings = Settings(
        auth="aws-iam", user="app_user", host="db.rds", port=5432, region="eu-west-1"
    )
    token = credential_source(settings)
    assert (token(), token()) == ("token-1", "token-2")
    [rds] = aws_clients
    assert (rds.service, rds.region) == ("rds", "eu-west-1")
    assert rds.calls[0] == {"DBHostname": "db.rds", "Port": 5432, "DBUsername": "app_user"}


def test_password_from_the_rds_managed_secret(aws_clients):
    arn = "arn:aws:secretsmanager:ap-south-1:111122223333:secret:rds!db-1"
    settings = Settings(auth="password", user="dbadmin", host="db.rds", password_secret_arn=arn)
    password = credential_source(settings)
    assert password() == "rotated"
    [secrets] = aws_clients
    assert (secrets.service, secrets.region, secrets.calls) == (
        "secretsmanager",
        "ap-south-1",
        [arn],
    )


def test_entra_token_for_the_managed_identity(monkeypatch):
    import azure.identity

    scopes = []

    class FakeCredential:
        def get_token(self, scope):
            scopes.append(scope)
            return type("AccessToken", (), {"token": "entra-token"})()

    monkeypatch.setattr(azure.identity, "DefaultAzureCredential", FakeCredential)
    token = credential_source(Settings(auth="azure-entra", user="app_user", host="h"))
    assert token() == "entra-token"
    assert scopes == ["https://ossrdbms-aad.database.windows.net/.default"]


def test_a_failed_sign_in_is_reported(monkeypatch):
    import azure.identity

    class BrokenCredential:
        def get_token(self, _scope):
            raise RuntimeError("no identity endpoint")

    monkeypatch.setattr(azure.identity, "DefaultAzureCredential", BrokenCredential)
    database = Database(Settings(auth="azure-entra", user="app_user", host="127.0.0.1"))
    try:
        with pytest.raises(SignInError, match="azure-entra credential for app_user"):
            database.engine.connect()
    finally:
        database.dispose()


def test_tls_settings_reach_the_driver(monkeypatch):
    seen = {}

    def connect(**kwargs):
        seen.update(kwargs)
        raise OSError("stop before the network")

    import psycopg

    monkeypatch.setattr(psycopg, "connect", connect)
    database = Database(Settings(auth="password", user="u", host="db", password="pw"))
    try:
        with pytest.raises(OSError, match="stop before"):
            database.engine.connect()
    finally:
        database.dispose()
    assert seen["sslmode"] == "verify-full"
    assert seen["sslrootcert"].endswith("cacert.pem")
    assert seen["password"] == "pw"
    assert seen["application_name"] == "enterprise-multi-cloud"


def test_ready_without_a_database(client):
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.get_json()["database"] == "not configured"


def test_ready_reports_a_misconfiguration(client, monkeypatch):
    monkeypatch.setenv("DB_AUTH", "password")
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.get_json()["database"] == "unreachable"


def test_ready_reports_an_unreachable_database(client, monkeypatch):
    # Nothing listens on port 1, so the connection is refused at once
    for key, value in env(DB_HOST="127.0.0.1", DB_PORT="1", DB_PASSWORD="x").items():
        monkeypatch.setenv(key, value)
    monkeypatch.setenv("DB_SSLMODE", "disable")
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.get_json() == {
        "status": "unavailable",
        "service": "enterprise-multi-cloud",
        "database": "unreachable",
        "version": "dev",
    }


def test_ready_with_a_database(client, connected):
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.get_json()["database"] == "ok"


def test_the_pool_is_kept_per_process(connected):
    first = db.get_database()
    assert db.get_database() is first
    db.reset()
    assert db.get_database() is not first


def test_sessions_get_time_limits(connected):
    with db.get_database().engine.connect() as connection:
        assert connection.execute(text("SHOW statement_timeout")).scalar() == "5s"
        idle = connection.execute(text("SHOW idle_in_transaction_session_timeout")).scalar()
        assert idle == "1min"


class FakeConnector:
    """Stands in for the Cloud SQL connector: hands out pg8000 connections to the test server
    the way the real one does after IAM sign-in."""

    instances = []

    def __init__(self, server, **options):
        self.server = server
        self.options = options
        self.calls = []
        self.closed = False
        FakeConnector.instances.append(self)

    def connect(self, instance, driver, **kwargs):
        self.calls.append((instance, driver, kwargs))
        if instance.endswith(":broken"):
            raise ConnectionError("Cloud SQL Admin API unreachable")
        return pg8000.dbapi.connect(
            self.server.admin_url.username,
            host=self.server.host,
            port=self.server.port,
            database=kwargs["db"],
            password=self.server.admin_url.password,
            application_name=kwargs["application_name"],
        )

    def close(self):
        self.closed = True


@pytest.fixture
def cloud_sql(server, monkeypatch):
    import google.cloud.sql.connector

    FakeConnector.instances = []
    monkeypatch.setattr(
        google.cloud.sql.connector,
        "Connector",
        lambda **options: FakeConnector(server, **options),
    )
    return FakeConnector


def test_cloud_sql_connections_go_through_the_connector(server, cloud_sql, monkeypatch):
    monkeypatch.setenv("DB_AUTH", "gcp-iam")
    monkeypatch.setenv("DB_INSTANCE", "project:region:instance")
    monkeypatch.setenv("DB_USER", "app-runtime@project.iam")
    monkeypatch.setenv("DB_NAME", server.database)
    assert db.ping() == "ok"
    [connector] = cloud_sql.instances
    assert connector.options["enable_iam_auth"] is True
    assert connector.options["ip_type"].value == "PRIVATE"
    assert connector.options["refresh_strategy"] == "lazy"
    instance, driver, kwargs = connector.calls[0]
    assert (instance, driver) == ("project:region:instance", "pg8000")
    assert kwargs["user"] == "app-runtime@project.iam"
    db.reset()
    assert connector.closed


def test_cloud_sql_connector_failures_are_sign_in_errors(server, cloud_sql):
    settings = Settings(auth="gcp-iam", user="u", instance="project:region:broken")
    database = Database(settings, database=server.database)
    try:
        with pytest.raises(SignInError, match="Cloud SQL connection to project:region:broken"):
            database.engine.connect()
    finally:
        database.dispose()


def test_cloud_sql_refusals_are_reported_by_postgresql(server, cloud_sql):
    settings = Settings(auth="gcp-iam", user="u", instance="project:region:instance")
    database = Database(settings, database="no_such_database")
    try:
        with pytest.raises(DBAPIError, match="no_such_database"):
            database.engine.connect()
    finally:
        database.dispose()
    assert scalar(server, "SELECT 1") == 1
