FROM python:3.14-slim@sha256:a2b82f3c48559aa0a8446d9af49826b6e2b2016f4cd2afabfe6013ec53729170

# The commit SHA the image was built from; reported by /health
ARG APP_VERSION=dev

LABEL org.opencontainers.image.title="enterprise-multi-cloud" \
      org.opencontainers.image.source="https://github.com/Naresh1401/enterprise-multi-cloud" \
      org.opencontainers.image.revision="${APP_VERSION}"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PORT=8000 \
    APP_VERSION=${APP_VERSION}

WORKDIR /app

COPY requirements.txt ./
# setuptools and wheel are only build tools; removing them drops the
# vulnerable copies they vendor and that the service never loads
RUN pip install --no-cache-dir -r requirements.txt \
    && pip uninstall --yes setuptools wheel \
    && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app

COPY gunicorn.conf.py ./
COPY app ./app

USER 10001

EXPOSE 8000

# urlopen raises on a refused connection or a non-2xx response, which fails the check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:' + os.environ.get('PORT', '8000') + '/health', timeout=2)"]

CMD ["gunicorn", "--config", "gunicorn.conf.py", "app.main:app"]
