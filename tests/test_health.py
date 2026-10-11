import runpy
from pathlib import Path

import pytest

from app.main import SERVICE_NAME, app

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def client():
    app.config.update(TESTING=True)
    return app.test_client()


def test_health_endpoint(client, monkeypatch):
    monkeypatch.delenv("APP_VERSION", raising=False)
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "healthy", "service": SERVICE_NAME, "version": "dev"}


def test_health_reports_the_deployed_version(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "3f2c1ab")
    assert client.get("/health").get_json()["version"] == "3f2c1ab"


def test_root_endpoint(client, monkeypatch):
    monkeypatch.setenv("APP_ENV", "production")
    response = client.get("/")
    assert response.status_code == 200
    body = response.get_json()
    assert body["status"] == "ok"
    assert body["service"] == SERVICE_NAME
    assert body["environment"] == "production"


def test_unknown_route_returns_json_404(client):
    response = client.get("/does-not-exist")
    assert response.status_code == 404
    assert response.get_json() == {"status": "error", "error": "not found"}


def test_wrong_method_returns_json_405(client):
    response = client.post("/health")
    assert response.status_code == 405
    assert response.get_json() == {"status": "error", "error": "method not allowed"}


def test_security_headers_are_set(client):
    headers = client.get("/health").headers
    assert headers["X-Content-Type-Options"] == "nosniff"
    assert headers["X-Frame-Options"] == "DENY"
    assert headers["Referrer-Policy"] == "no-referrer"
    assert headers["Cache-Control"] == "no-store"


def test_gunicorn_binds_to_the_platform_port(monkeypatch):
    monkeypatch.setenv("PORT", "9090")
    settings = runpy.run_path(str(ROOT / "gunicorn.conf.py"))
    assert settings["bind"] == "0.0.0.0:9090"


def test_gunicorn_defaults_to_port_8000(monkeypatch):
    monkeypatch.delenv("PORT", raising=False)
    settings = runpy.run_path(str(ROOT / "gunicorn.conf.py"))
    assert settings["bind"] == "0.0.0.0:8000"


def test_gunicorn_admin_socket_is_disabled():
    settings = runpy.run_path(str(ROOT / "gunicorn.conf.py"))
    assert settings["control_socket_disable"] is True
