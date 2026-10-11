"""Gunicorn settings for the container image.

Cloud Run and Azure Container Apps route traffic to the port in PORT.
"""

import os

bind = f"0.0.0.0:{os.environ.get('PORT', '8000')}"
workers = int(os.environ.get("WEB_CONCURRENCY", "2"))
threads = int(os.environ.get("GUNICORN_THREADS", "4"))
timeout = int(os.environ.get("GUNICORN_TIMEOUT", "30"))
graceful_timeout = 20
worker_tmp_dir = "/dev/shm"
accesslog = "-"
errorlog = "-"

# The gunicornc admin socket has no use on a managed container platform
control_socket_disable = True
