# Application — Project 02

A three-tier notes application. Deliberately small: the app is never the hard
part, the Kubernetes objects around it are.

---

## Components

| Directory | Image | Language / stack | Port | State |
|---|---|---|---|---|
| [`frontend/`](frontend/) | `notes-web:1.0.0` | Python 3.13 · Flask · gunicorn | 8080 | none |
| [`backend/`](backend/) | `notes-api:1.0.0` | Python 3.13 · Flask · gunicorn · psycopg 3 | 8080 | none |
| [`database/`](database/) | `postgres:17.5-alpine` | PostgreSQL 17 | 5432 | **all of it** |

---

## API surface (`notes-api`)

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/notes` | List notes, oldest first |
| `POST` | `/api/notes` | Create one — `{"body": "…"}` |
| `DELETE` | `/api/notes?id=N` | Delete one |
| `GET` | `/api/info` | Which pod answered, which database, whether it is connected, how many notes |
| `GET` | `/livez` | **Liveness.** Is this process answering? **Never touches the database** |
| `GET` | `/healthz` | **Readiness.** Opens a real database connection; 503 if it fails |

`notes-web` serves `/` and proxies `/api/*` to `notes-api`; it also exposes
`/livez`, `/healthz` and `/whoami`.

> The two health endpoints exist so stage 11 can be *demonstrated* rather than
> asserted. Point liveness at `/healthz` and watch a database blip restart every
> API pod — that is failure lab 8.

---

## Run locally with Docker first

Do this before touching Kubernetes. If it is broken here it is an application
bug; if it works here and fails in the cluster, the problem is your manifests.

```bash
docker network create notes-test

docker run -d --name pg --network notes-test \
  -e POSTGRES_DB=notes -e POSTGRES_USER=notes -e POSTGRES_PASSWORD=devpassword \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v "$PWD/database/init.sql:/docker-entrypoint-initdb.d/10-init.sql:ro" \
  postgres:17.5-alpine
sleep 12

docker run -d --name notes-api --network notes-test \
  -e POSTGRES_HOST=pg -e POSTGRES_DB=notes -e POSTGRES_USER=notes \
  -e POSTGRES_PASSWORD=devpassword -e POD_NAME=local-api \
  -p 18081:8080 notes-api:1.0.0

docker run -d --name notes-web --network notes-test \
  -e NOTES_API_URL=http://notes-api:8080 -e POD_NAME=local-web \
  -p 18080:8080 notes-web:1.0.0

sleep 5
curl -s localhost:18080/api/info; echo
curl -sX POST localhost:18080/api/notes -H 'Content-Type: application/json' -d '{"body":"hello"}'
open http://localhost:18080
```

Expected: `{"db_connected":true, …, "note_count":2, …}` and a created note with
`"id":3`.

**Try the readiness behaviour while you are here:**

```bash
docker stop pg
curl -s -o /dev/null -w 'healthz: %{http_code}\n' localhost:18081/healthz   # 503
curl -s -o /dev/null -w 'livez:   %{http_code}\n' localhost:18081/livez     # 200
docker start pg && sleep 8
curl -s -o /dev/null -w 'healthz: %{http_code}\n' localhost:18081/healthz   # 200
```

▸ That is precisely the distinction stage 11 is built on, visible in four
commands.

**Clean up:**

```bash
docker rm -f pg notes-api notes-web && docker network rm notes-test
```

---

## Build for the cluster

```bash
docker build -t notes-api:1.0.0 backend
docker build -t notes-web:1.0.0 frontend
kind load docker-image notes-api:1.0.0 --name kubernetes-lab
kind load docker-image notes-web:1.0.0 --name kubernetes-lab
```

The `kind load` step is not optional — a Kind node has its own image store.
Skip it and you get `ImagePullBackOff`.

---

## Configuration contract

Everything comes from the environment. **The image never changes between
stages; only the environment does** — which is what makes ConfigMaps and Secrets
teachable rather than decorative.

| Variable | Read by | Default | Source, by stage |
|---|---|---|---|
| `POSTGRES_HOST` | api, init container | `127.0.0.1` | 03 pod IP → 04 Service DNS → 05 ConfigMap |
| `POSTGRES_PORT` | api, init container | `5432` | 05 ConfigMap |
| `POSTGRES_DB` | api, postgres | `notes` | 05 ConfigMap |
| `POSTGRES_USER` | api, postgres | `notes` | 05 ConfigMap |
| `POSTGRES_PASSWORD` | api, postgres | *(empty)* | 03 literal → 06 **Secret** |
| `NOTES_API_URL` | web | `http://127.0.0.1:8080` | 03 pod IP → 04 Service DNS → 05 ConfigMap |
| `APP_ENV` | api, web | `development` | 05 ConfigMap |
| `LOG_LEVEL` | api | `info` | 05 ConfigMap |
| `PGDATA` | postgres | image default | 07 onward — a **subdirectory** of the mount |
| `POD_NAME` | api, web | `unknown` | Downward API (`fieldRef: metadata.name`) |

---

## Design notes

**Why the web tier proxies instead of letting the browser call the API.**
It makes `notes-web` a genuine in-cluster consumer of `notes-api` — resolving it
by DNS, connecting over the cluster network. That is exactly the problem a
Service solves. If the browser called the API directly, "pod IPs are unstable"
would be a claim you read instead of a failure you watch. It also gives the
Ingress two real backends to route between.

**Why a new database connection per request.** A connection pool would hide
failures behind a stale socket. Reconnecting per request means every request
re-resolves DNS and re-connects, so deleting the database pod produces an
immediate, visible error rather than a mysterious hang. A production service
would pool — and at scale would put PgBouncer in front.

**Why the API retries at start-up.** `ensure_schema()` retries for ~60 seconds
while PostgreSQL boots, so stages 03–10 work before any init container exists.
The retry is deliberately **bounded**: a genuinely unreachable database still
fails loudly rather than hanging forever.

**Why two workers per pod here, and one in Project 01.** Project 01 kept tasks in
process memory, so a second worker would have had its own copy of the data.
Nothing here holds state in the process, so multiple workers and multiple
replicas all see the same rows. **That is what "stateless tier, stateful backing
store" means in practice** — and it is why refreshing the UI changes the *pod
name* but never the *note list*.

---

## Dockerfile requirements in this repo

| Rule | Why |
|---|---|
| Two-stage build | No compilers or pip cache in the runtime image |
| Non-root user (UID 10001) | Project 07 enforces `runAsNonRoot` cluster-wide; start correct |
| Explicit version tags, never `:latest` | A rollback must mean something |
| Pinned dependencies | A rebuilt image behaves like the one you tested |
| gunicorn, not Flask's dev server | Graceful SIGTERM handling — required for zero-downtime rollouts |
| `EXPOSE` and a named container port | Services and probes reference the **name**, not the number |
