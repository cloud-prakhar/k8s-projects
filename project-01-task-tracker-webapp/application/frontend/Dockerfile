FROM python:3.13-slim AS build
WORKDIR /app
COPY requirements.txt .
RUN python -m venv /venv \
 && /venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.13-slim
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
ENV PATH="/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
COPY --from=build /venv /venv
WORKDIR /app
COPY app.py .
COPY static /static
USER 10001:10001
EXPOSE 8080
# This tier is stateless, so multiple workers are safe here.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", \
     "--graceful-timeout", "25", "--access-logfile", "-", "app:app"]
