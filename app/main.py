"""HTTP entry point for the sample service that the pipeline builds and deploys."""

import os

from flask import Flask, jsonify

SERVICE_NAME = "enterprise-multi-cloud-cicd"

app = Flask(__name__)


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
    return jsonify(status="healthy", service=SERVICE_NAME, version=_version())


@app.errorhandler(404)
def not_found(_error):
    return jsonify(status="error", error="not found"), 404


@app.errorhandler(405)
def method_not_allowed(_error):
    return jsonify(status="error", error="method not allowed"), 405


if __name__ == "__main__":
    # Local development only; the container image serves the app with gunicorn.
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), debug=False)
