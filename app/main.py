"""HTTP entry point for the sample service that the pipeline builds and deploys."""

import logging
import os

from flask import Flask, jsonify

from app import db
from app.items import bp as items_api

SERVICE_NAME = "enterprise-multi-cloud"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)
# Request bodies are small JSON documents; anything bigger is refused unread
app.config["MAX_CONTENT_LENGTH"] = 16 * 1024
app.register_blueprint(items_api)


def _version() -> str:
    # Baked into the image from the commit SHA and set again by each cloud
    # deployment, so a live /health response identifies the running commit.
    return os.environ.get("APP_VERSION", "dev")


def _environment() -> str:
    return os.environ.get("APP_ENV", "development")


@app.after_request
def add_security_headers(response):
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Referrer-Policy", "no-referrer")
    response.headers.setdefault("Cache-Control", "no-store")
    return response


@app.get("/")
def index():
    return jsonify(
        service=SERVICE_NAME,
        status="ok",
        environment=_environment(),
        version=_version(),
        message="Application is running successfully.",
    )


@app.get("/health")
def health():
    # Liveness: the process answers. It never touches the database, so a database outage
    # doesn't get every copy of the service restarted.
    return jsonify(status="healthy", service=SERVICE_NAME, version=_version())


@app.get("/ready")
def ready():
    # Readiness: the process answers and, when it has a database, can query it. Traffic
    # only goes to copies that are ready.
    try:
        database = db.ping()
    except Exception:
        # The reason goes to the log, not to whoever is probing
        log.warning("Readiness check failed", exc_info=True)
        return jsonify(
            status="unavailable", service=SERVICE_NAME, database="unreachable", version=_version()
        ), 503
    return jsonify(status="ready", service=SERVICE_NAME, database=database, version=_version())


@app.errorhandler(404)
def not_found(_error):
    return jsonify(status="error", error="not found"), 404


@app.errorhandler(405)
def method_not_allowed(_error):
    return jsonify(status="error", error="method not allowed"), 405


@app.errorhandler(413)
def too_large(_error):
    return jsonify(status="error", error="request body too large"), 413


@app.errorhandler(500)
def internal_error(_error):
    return jsonify(status="error", error="internal error"), 500


if __name__ == "__main__":
    # Local development only; the container image serves the app with gunicorn.
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), debug=False)
