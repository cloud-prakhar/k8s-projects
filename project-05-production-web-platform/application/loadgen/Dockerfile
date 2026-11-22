# The load generator uses only the Python standard library — nothing to pin,
# nothing to install. Non-root like every image in this repository.
FROM python:3.13-slim
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY loadgen.py .
USER 10001:10001
ENTRYPOINT ["python", "/app/loadgen.py"]
