from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/")
def index():
    return jsonify({
        "service": "enterprise-multi-cloud-cicd",
        "status": "ok",
        "message": "Application is running successfully."
    })


@app.get("/health")
def health():
    return jsonify({
        "status": "healthy",
        "service": "enterprise-multi-cloud-cicd"
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000, debug=False)
