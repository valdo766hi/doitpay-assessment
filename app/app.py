from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.get("/health")
def health():
    return jsonify({"status": "ok"}), 200

@app.get("/ready")
def ready():
    return jsonify({"ready": True}), 200

@app.get("/")
def index():
    return jsonify({
        "service": "paytrack-api",
        "environment": os.getenv("APP_ENV", "development")
    }), 200

if __name__ == "__main__":
    # Development entrypoint only; production should use a production WSGI server.
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")), debug=True)
