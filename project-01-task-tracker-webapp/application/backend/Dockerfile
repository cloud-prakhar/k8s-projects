# Two-stage build: install dependencies into a virtualenv, then copy just that
# venv into a clean runtime image. The final image carries no build tools, no
# pip cache and no compiler — smaller to pull on every schedule, and a smaller
# attack surface.
FROM python:3.13-slim AS build
WORKDIR /app
COPY requirements.txt .
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
# ONE worker, several threads — deliberate. Tasks live in this process's memory,
# so a second worker would have its own copy and the app would return different
# data depending on which one answered. Scaling therefore has to happen at the
# POD level (that is what replicas are for), and even then each Pod holds its
# own tasks. That limitation is the exact problem Project 02 solves with a
# database. Real stateless services do run multiple workers per Pod.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "8", \
     "--graceful-timeout", "25", "--access-logfile", "-", "app:app"]
