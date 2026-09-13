# Two-stage build: dependencies into a virtualenv, then only that virtualenv in
# a clean runtime image — no compiler, no pip cache, a smaller attack surface.
FROM python:3.13-slim AS build
WORKDIR /app
COPY requirements.txt .
# psycopg[binary] ships prebuilt wheels, so no libpq-dev / gcc is needed.
RUN python -m venv /venv \
 && /venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.13-slim
# Non-root from the start. Project 07 enforces runAsNonRoot; nothing will have
# to change then.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
ENV PATH="/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
COPY --from=build /venv /venv
WORKDIR /app
COPY settings.py migrations.py migrate.py app.py ./
USER 10001:10001
EXPOSE 8080
# ONE worker, eight threads. The API keeps no data in the process, but it does
# keep diagnostic counters (/api/info → stats). One worker means those counters
# describe the whole pod instead of whichever worker happened to answer.
# gunicorn handles SIGTERM gracefully: stop accepting, finish in-flight requests.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "8", \
     "--graceful-timeout", "25", "--access-logfile", "-", "app:app"]
