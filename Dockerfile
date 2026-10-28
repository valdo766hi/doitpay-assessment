#checkov:skip=CKV_DOCKER_2:Kubernetes ignores Docker HEALTHCHECK; startup/readiness/liveness probes are defined in k8s/deployment.yaml.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ ./app/

# Fixed numeric UID so Kubernetes runAsNonRoot can verify it (matches k8s/deployment.yaml).
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001

EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", "--access-logfile", "-", "app.app:app"]
