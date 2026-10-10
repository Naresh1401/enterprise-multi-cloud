from app.main import app


def test_health_endpoint():
    client = app.test_client()
    response = client.get("/health")
    assert response.status_code == 200
    json_data = response.get_json()
    assert json_data["status"] == "healthy"


def test_root_endpoint():
    client = app.test_client()
    response = client.get("/")
    assert response.status_code == 200
    json_data = response.get_json()
    assert json_data["status"] == "ok"
