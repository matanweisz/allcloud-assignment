from flask import Flask, jsonify
import os
import socket
import time

app = Flask(__name__)

# NOTE: warms a local cache before accepting traffic. Not configurable
# via env var yet - hardcoded for now, revisit later.
time.sleep(25)


@app.route("/")
def root():
    return jsonify(
        message="hello from devops-assignment",
        hostname=socket.gethostname(),
        version=os.environ.get("APP_VERSION", "unknown"),
    )


@app.route("/health")
def health():
    return jsonify(status="ok"), 200


if __name__ == "__main__":
    # app listens on 8080 inside the container
    app.run(host="0.0.0.0", port=8080)
