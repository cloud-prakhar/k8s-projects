# Application — Project 01

The two-tier app being deployed. **Run it with plain Docker first** — if you can't run it locally, you can't tell
whether a Kubernetes problem is actually a Kubernetes problem.

## Components

| Directory | Language | Image | Port | Health endpoints |
|---|---|---|---|---|
| `frontend/` | Python 3.13 · Flask · gunicorn | `task-web:1.0.0` | 8080 | `/healthz`, `/livez`, `/whoami` |
| `backend/` | Python 3.13 · Flask · gunicorn | `task-api:1.0.0` | 8080 | `/healthz`, `/livez` |

## API surface (`task-api`)

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/tasks` | List tasks |
| POST | `/api/tasks` | Create — `{"title": "..."}` |
| DELETE | `/api/tasks?id=N` | Delete |
| GET | `/api/info` | **Which Pod answered** + its config — the key teaching endpoint |
| GET | `/healthz` | **Readiness** — can I serve right now? |
| GET | `/livez` | **Liveness** — is this process alive? |
| GET/POST | `/debug/toggle-ready` | 🧪 Lab-only: flip readiness **without** killing the process |

> Two separate health endpoints exist so you can watch a Pod get removed from a Service while the container keeps
> running — the difference between readiness and liveness, made visible.

## Run locally with Docker

```bash
docker build -t task-api:1.0.0 backend
docker build -t task-web:1.0.0 frontend

docker network create tasknet
docker run -d --name api --network tasknet -e APP_ENV=local task-api:1.0.0
docker run -d --name web --network tasknet -p 18080:8080 -e TASK_API_URL=http://api:8080 task-web:1.0.0

curl -s localhost:18080/api/tasks
curl -s localhost:18080/api/info
open http://localhost:18080

docker rm -f api web && docker network rm tasknet
```

## Build for the cluster

```bash
../scripts/build-images.sh      # docker build + kind load docker-image
```

## Configuration contract

Everything the app reads from the environment — exactly what becomes ConfigMap and Secret keys.

| Variable | Source | Default | Purpose |
|---|---|---|---|
| `APP_ENV` | ConfigMap | `development` | Reported by `/api/info` |
| `LOG_LEVEL` | ConfigMap | `info` | `debug` logs every request |
| `TASK_API_URL` | ConfigMap | `http://127.0.0.1:8080` | Where `task-web` proxies `/api/*` |
| `API_TOKEN` | **Secret** | *(empty)* | When set, the API **requires** `X-API-Token` |
| `POD_NAME` | **Downward API** | `unknown` | Which Pod answered |
| `PORT` | — | `8080` | Listen port |

## Design notes

**Why the web tier proxies rather than the browser calling the API.** It makes `task-web` a real in-cluster client:
it resolves `task-api` by DNS and connects over the cluster network. That is precisely the problem a Service solves.
A browser calling the API directly would bypass the mechanism being taught.

**Why the API runs one gunicorn worker.** Tasks live in the process's memory. Two workers would each keep their own
copy and return different data depending on which answered. That constraint is deliberate and visible — and it's the
motivation for Project 02.

## Dockerfile requirements in this repo

- Multi-stage build; dependencies into a venv, only the venv into the runtime image
- **Non-root** (`USER 10001`) — Project 07 enforces `runAsNonRoot` cluster-wide
- Explicit version tags, never `latest`
- Pinned dependencies in `requirements.txt`
- Binds `0.0.0.0`, never `127.0.0.1` — a loopback-bound container is unreachable from the cluster, silently
- gunicorn handles SIGTERM gracefully (`--graceful-timeout 25`), which is what makes zero-downtime rollouts real
- Separate `/healthz` (readiness) and `/livez` (liveness) endpoints
