import pytest

from tests.conftest import scalar


def test_items_need_a_database(client):
    response = client.get("/api/items")
    assert response.status_code == 503
    assert response.get_json() == {"status": "error", "error": "database not configured"}


def test_items_when_the_database_is_down(client, monkeypatch):
    for key, value in {
        "DB_AUTH": "password",
        "DB_HOST": "127.0.0.1",
        "DB_PORT": "1",
        "DB_USER": "app",
        "DB_PASSWORD": "x",
        "DB_SSLMODE": "disable",
    }.items():
        monkeypatch.setenv(key, value)
    response = client.get("/api/items")
    assert response.status_code == 503
    assert response.headers["Retry-After"] == "5"
    assert response.get_json() == {"status": "error", "error": "database unavailable"}


def test_items_with_bad_settings(client, monkeypatch):
    monkeypatch.setenv("DB_AUTH", "password")
    response = client.post("/api/items", json={"name": "x"})
    assert response.status_code == 503
    assert response.get_json()["error"] == "database unavailable"


def test_create_list_and_get(client, connected):
    created = client.post("/api/items", json={"name": "  first  "})
    assert created.status_code == 201
    item = created.get_json()
    assert item["name"] == "first"
    assert item["created_at"]

    second = client.post("/api/items", json={"name": "second"}).get_json()
    listed = client.get("/api/items").get_json()["items"]
    assert [entry["id"] for entry in listed[:2]] == [second["id"], item["id"]]

    fetched = client.get(f"/api/items/{item['id']}")
    assert fetched.status_code == 200
    assert fetched.get_json() == item


def test_unknown_item(client, connected):
    response = client.get("/api/items/987654321")
    assert response.status_code == 404
    assert response.get_json() == {"status": "error", "error": "not found"}


@pytest.mark.parametrize(
    "body",
    [
        {"json": {"name": ""}},
        {"json": {"name": "   "}},
        {"json": {"name": "x" * 101}},
        {"json": {"name": 42}},
        {"json": {"title": "no name"}},
        {"json": ["name"]},
        {"data": "not json", "content_type": "application/json"},
    ],
)
def test_invalid_items_are_refused(client, connected, body):
    response = client.post("/api/items", **body)
    assert response.status_code == 400
    assert response.get_json()["error"] == "name must be text of 1 to 100 characters"


def test_large_bodies_are_refused(client, connected):
    response = client.post("/api/items", data="x" * 20_000, content_type="application/json")
    assert response.status_code == 413
    assert response.get_json() == {"status": "error", "error": "request body too large"}


def test_the_database_enforces_the_name_rules(server, connected):
    # A second line of defence for writers other than the API
    with pytest.raises(Exception, match="items_name_length"):
        scalar(
            server,
            "INSERT INTO app.items (name) VALUES ('   ') RETURNING id",
            connected.name,
            connected.password,
        )


def test_query_bugs_are_errors_not_outages(client, connected, monkeypatch):
    from sqlalchemy import Column, Integer, MetaData, Table

    import app.items

    missing = Table("no_such_table", MetaData(schema="app"), Column("id", Integer))
    monkeypatch.setattr(app.items, "items", missing)
    monkeypatch.setitem(client.application.config, "PROPAGATE_EXCEPTIONS", False)
    response = client.get("/api/items/1")
    assert response.status_code == 500
    assert response.get_json() == {"status": "error", "error": "internal error"}


def test_slow_queries_are_cut_off(client, connected, monkeypatch):
    from sqlalchemy import text

    import app.items

    class SlowQuery:
        def where(self, *_conditions):
            return text("SELECT pg_sleep(2)")

    monkeypatch.setenv("DB_STATEMENT_TIMEOUT_MS", "200")
    monkeypatch.setattr(app.items, "select", lambda *_columns: SlowQuery())
    response = client.get("/api/items/1")
    assert response.status_code == 503
    assert response.get_json() == {"status": "error", "error": "database unavailable"}
