# Two-stage build: dependencies into a virtualenv, then only that virtualenv in
# a clean runtime image — no compiler, no pip cache, a smaller attack surface.
FROM python:3.13-slim AS build
WORKDIR /app
COPY requirements.txt .
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
COPY app.py ./
USER 10001:10001
EXPOSE 8080
# ONE worker: `callers_seen` lives in process memory and is the evidence that
# stage 15's NetworkPolicy works. Split it across workers and the proof is
# split too.
#
# THREADS matter here: PAYMENT_LATENCY_MS makes each request sleep, and a
# thread-per-request worker keeps the service slow rather than unavailable —
# which is exactly the cascading failure this project demonstrates.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "8", \
     "--graceful-timeout", "25", "--access-logfile", "-", "app:app"]
