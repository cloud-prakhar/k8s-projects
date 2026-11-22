# Two-stage build: dependencies into a virtualenv, then only that virtualenv in
# a clean runtime image — no compiler, no pip cache, a smaller attack surface.
FROM python:3.13-slim AS build
WORKDIR /app
COPY requirements.txt .
RUN python -m venv /venv \
 && /venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.13-slim
# The version is baked in at BUILD time, so 1.0.0 and 2.0.0 are genuinely
# different images — a rollout changes the image, not just an env var.
#   docker build --build-arg APP_VERSION=2.0.0 -t …:webapp-2.0.0 .
ARG APP_VERSION=1.0.0
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
ENV PATH="/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION=${APP_VERSION}
COPY --from=build /venv /venv
WORKDIR /app
COPY app.py .
USER 10001:10001
EXPOSE 8080
# TWO workers × FOUR threads = up to 8 concurrent requests per pod, and up to
# 2 CPUs of Python work (one per worker process — the GIL limits each to one).
#
# --graceful-timeout 25: on SIGTERM gunicorn STOPS ACCEPTING new connections at
# once, then gives in-flight requests up to 25 s. "Stops accepting at once" is
# exactly why a rollout without a preStop hook drops requests: the load balancer
# has not yet noticed the pod is leaving (stage 11).
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", \
     "--graceful-timeout", "25", "--access-logfile", "-", "app:app"]
