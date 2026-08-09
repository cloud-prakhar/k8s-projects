# Application — Project XX

The app being deployed. **Run it with plain Docker first** — if you can't run it locally, you can't tell whether a
Kubernetes problem is a Kubernetes problem.

## Components

| Directory | Language | Image | Port | Health endpoints |
|---|---|---|---|---|
| `frontend/` | | `<project>-frontend:1.0.0` | | |
| `backend/` | | `<project>-backend:1.0.0` | | |
| `database/` | | upstream image | | |

## Run locally with Docker

```bash
docker build -t <project>-backend:1.0.0 backend/
docker run --rm -p 8080:8080 -e LOG_LEVEL=debug <project>-backend:1.0.0
curl localhost:8080/healthz
```

## Build for the cluster

```bash
../scripts/build-images.sh      # builds, then `kind load docker-image` into the cluster
```

## Configuration contract

Everything the app reads from the environment — this is exactly what becomes ConfigMaps and Secrets.

| Variable | Source | Default | Purpose |
|---|---|---|---|
| `LOG_LEVEL` | ConfigMap | `info` | |
| `DB_HOST` | ConfigMap | | |
| `DB_PASSWORD` | Secret | — | |

## Dockerfile requirements for this repo

- Multi-stage build; small final image
- **Non-root** user (`USER 1000`) — Project 07 enforces this
- Explicit version tag, never `latest`
- Listens on `0.0.0.0`, not `127.0.0.1`
- Handles `SIGTERM` and shuts down gracefully
- Exposes `/healthz` (readiness) and `/livez` (liveness) as **separate** endpoints
