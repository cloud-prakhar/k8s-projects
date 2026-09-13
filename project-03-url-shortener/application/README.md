# Application — Project 03

A URL shortener. Deliberately small: the app is never the hard part; the Kubernetes objects around it are.

---

## Components

| Directory | Image | Stack | Port | State |
|---|---|---|---|---|
| [`web/`](web/) | `cloudprakhargupta/url-shortener:web-1.0.0` | Python 3.13 · Flask · gunicorn | 8080 | none |
| [`api/`](api/) | `cloudprakhargupta/url-shortener:api-1.0.0` | Python 3.13 · Flask · gunicorn · psycopg 3 · redis-py | 8080 | none (diagnostic counters only) |
| [`collector/`](collector/) | `cloudprakhargupta/url-shortener:collector-1.0.0` | Python 3.13 · Flask · gunicorn | 8080 | event counts in memory |
| — | `postgres:17.5-alpine` | PostgreSQL 17 | 5432 | **links** |
| — | `redis:8.2.9-alpine` | Redis 8 | 6379 | cache + **click counters** |

---

## API surface (`shortener-api`)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/links` | `{"url": "https://…"}` → `{code, short_url, …}` (201) |
| `GET` | `/api/links` | Latest 20 links with click counts (`clicks: null` = Redis unreachable) |
| `GET` | `/api/links/<code>` | One link: target, clicks, remaining cache TTL |
| `GET` | `/r/<code>` | **The redirect.** `302` with `X-Served-By`, `X-Cache`, `X-Click-Counted`, `X-Click-Error` |
| `GET` | `/api/info` | Pod, config version, `CODE_LENGTH`, PostgreSQL status, **which Redis member each host reached**, analytics and write-error counters |
| `GET` | `/livez` | **Liveness** — the process only |
| `GET` | `/healthz` | **Readiness** — PostgreSQL only, never Redis |

`shortener-web` serves `/`, proxies `/api/*` and `/r/*`, and exposes `/livez`, `/healthz`, `/whoami`.
`analytics-collector` accepts `POST /events` and summarises on `GET /events`.

### The redirect path

1. Reject codes whose length ≠ `CODE_LENGTH` (stage 05's drift makes this visible).
2. `GET link:<code>` on `REDIS_READ_HOST` → hit, or
3. `SELECT target_url FROM links` → `SET link:<code> … EX CACHE_TTL_SECONDS` on `REDIS_WRITE_HOST`.
4. `INCR clicks:<code>` on `REDIS_WRITE_HOST` — failure recorded, **never** fails the redirect.
5. Fire-and-forget `POST ANALYTICS_URL`.

---

## Run locally with Docker first

```bash
docker network create us-test
docker run -d --name pg --network us-test \
  -e POSTGRES_DB=shortener -e POSTGRES_USER=shortener -e POSTGRES_PASSWORD=devpw postgres:17.5-alpine
docker run -d --name redis-0 --network us-test redis:8.2.9-alpine \
  redis-server --requirepass rpw --masterauth rpw --appendonly yes
docker run -d --name redis-1 --network us-test redis:8.2.9-alpine \
  redis-server --requirepass rpw --masterauth rpw --replicaof redis-0 6379
docker run -d --name analytics --network us-test cloudprakhargupta/url-shortener:collector-1.0.0
docker run -d --name api --network us-test -p 18081:8080 \
  -e POSTGRES_HOST=pg -e POSTGRES_PASSWORD=devpw -e REDIS_PASSWORD=rpw \
  -e REDIS_WRITE_HOST=redis-0 -e REDIS_READ_HOST=redis-1 \
  -e ANALYTICS_URL=http://analytics:8080/events \
  cloudprakhargupta/url-shortener:api-1.0.0
docker run -d --name web --network us-test -p 18080:8080 \
  -e SHORTENER_API_URL=http://api:8080 cloudprakhargupta/url-shortener:web-1.0.0
sleep 10
curl -s -X POST localhost:18080/api/links -H 'Content-Type: application/json' -d '{"url":"https://kubernetes.io"}'
open http://localhost:18080
```

**See the READONLY failure before Kubernetes ever produces it:**

```bash
docker run -d --name api-bad --network us-test -p 18082:8080 \
  -e POSTGRES_HOST=pg -e POSTGRES_PASSWORD=devpw -e REDIS_PASSWORD=rpw \
  -e REDIS_WRITE_HOST=redis-1 cloudprakhargupta/url-shortener:api-1.0.0
sleep 8
curl -sI localhost:18082/r/<code> | grep -i x-click
# X-Click-Counted: false
# X-Click-Error: You can't write against a read only replica.
```

**See Redis being optional:**

```bash
docker stop redis-0 redis-1
curl -sI localhost:18081/r/<code> | grep -iE '^(HTTP|x-)'           # still 302, X-Click-Counted: false
curl -s -o /dev/null -w '%{http_code}\n' localhost:18081/healthz    # still 200
```

**Clean up:**

```bash
docker rm -f pg redis-0 redis-1 analytics api api-bad web && docker network rm us-test
```

---

## Build for the cluster

```bash
docker login
../scripts/build-images.sh
# or elsewhere:  IMAGE_REPO=<acct>.dkr.ecr.us-east-1.amazonaws.com/url-shortener ../scripts/build-images.sh
```

EKS nodes can only run images they can pull from a registry. Publishing elsewhere means changing `images[].newName`
in `manifests/19-final/kustomization.yaml` — never the manifests.

---

## Configuration contract

Everything comes from the environment. **The image never changes between stages; only the environment does.**

| Variable | Read by | Default | Source, by stage |
|---|---|---|---|
| `POSTGRES_HOST` / `PORT` / `DB` / `USER` | api, `migrate` | `127.0.0.1` / `5432` / `shortener` / `shortener` | 03 literal → 05 ConfigMap |
| `POSTGRES_PASSWORD` | api, `migrate`, postgres | *(empty)* | 03 literal → 06 Secret |
| `REDIS_WRITE_HOST` | api | `127.0.0.1` | 03 `redis` → 05 ConfigMap → **08 `redis-0.redis-headless…`** |
| `REDIS_READ_HOST` | api | = write host | 03 `redis` → 05 ConfigMap |
| `REDIS_PORT` / `REDIS_PASSWORD` | api | `6379` / *(empty)* | 05 ConfigMap / 06 Secret |
| `CODE_LENGTH` | api | `6` | **must match on every replica** |
| `CACHE_TTL_SECONDS` | api | `300` | 05 ConfigMap |
| `PUBLIC_BASE_URL` | api | *(blank → from request Host)* | 05 ConfigMap |
| `ANALYTICS_URL` | api | *(blank → disabled)* | 03 `http://analytics/events` |
| `CONFIG_VERSION` | api | `none` | The ConfigMap names itself |
| `RUN_MIGRATIONS` | api | `true` | 11: `false` (init container migrates) |
| `SHORTENER_API_URL` | web | `http://127.0.0.1:8080` | 03 literal → 05 ConfigMap |
| `LOG_LEVEL`, `APP_ENV` | api, web | `info`, `development` | 05 ConfigMap |
| `POD_NAME` | all | `unknown` | Downward API |

---

## Design notes

**Short-lived connections to both datastores.** A pool pins to one backend and hides misrouting. One connection per
call means each request re-resolves DNS and passes through the Service's load balancing, so the READONLY failure
shows up on ~50% of requests instead of on one unlucky worker.

**Redis is optional by construction.** Every Redis call returns `(value, error)`; nothing raises into a request.
`/healthz` checks PostgreSQL only.

**Migrations take a PostgreSQL advisory lock** (`migrations.py`) and record versions in `schema_migrations`. Many
replicas — or many init containers — can start at once safely.

**One gunicorn worker in the API and collector.** The API's `/api/info` counters and the collector's event counts
live in process memory; one worker makes them describe the whole pod. The web tier has no such state and runs two.

**Why the password never appears on Redis's command line.** See stage 06 — the config is rendered into a tmpfs
emptyDir at start-up.

---

## Dockerfile rules in this repo

| Rule | Why |
|---|---|
| Two-stage build | No compilers or pip cache in the runtime image |
| Non-root user (UID 10001) | Project 07 enforces `runAsNonRoot` |
| Explicit tags, never `:latest` | A rollback must mean something |
| Pinned dependencies | A rebuilt image behaves like the tested one |
| gunicorn, not Flask's dev server | Graceful SIGTERM handling |
| Named container port `http` | Services, probes and the ALB reference the name |
