# Two-stage build: install dependencies into a virtualenv, then copy just that
# venv into a clean runtime image. The final image carries no build tools, no
# pip cache and no compiler — smaller to pull on every schedule, and a smaller
# attack surface.
FROM python:3.13-slim AS build
WORKDIR /app
COPY requirements.txt .
# psycopg[binary] ships prebuilt wheels, so no libpq-dev / gcc is needed here.
RUN python -m venv /venv \
 && /venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.13-slim
# Run as a non-root user. Project 07 enforces runAsNonRoot cluster-wide;
# starting non-root here means nothing has to change later.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
ENV PATH="/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
COPY --from=build /venv /venv
WORKDIR /app
COPY app.py .
USER 10001:10001
EXPOSE 8080
# gunicorn handles SIGTERM gracefully: it stops accepting new connections and
# lets in-flight requests finish. Ignoring SIGTERM is how you get dropped
# requests on every rollout.
# Unlike Project 01, this tier holds NO state in the process — every note is in
# PostgreSQL — so multiple workers are safe and every replica sees the same
# data. That is what "stateless tier, stateful backing store" means in practice.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", \
     "--graceful-timeout", "25", "--access-logfile", "-", "app:app"]
