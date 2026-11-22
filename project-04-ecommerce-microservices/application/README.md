# Application — Project 04

Five small services. Deliberately small: the application is never the hard part; the Kubernetes objects around it
are. What matters here is the **call graph**, because this is the first project where one user action crosses
several services.

---

## Components

| Directory | Image | Stack | Port | State |
|---|---|---|---|---|
| [`storefront/`](storefront/) | `cloudprakhargupta/ecommerce:storefront-1.0.0` | Python 3.13 · Flask · gunicorn | 8080 | none |
| [`catalog/`](catalog/) | `cloudprakhargupta/ecommerce:catalog-1.0.0` | Flask · psycopg 3 | 8080 | none (owns the `catalog` **database**) |
| [`cart/`](cart/) | `cloudprakhargupta/ecommerce:cart-1.0.0` | Flask · redis-py | 8080 | none (baskets live in Redis) |
| [`order/`](order/) | `cloudprakhargupta/ecommerce:order-1.0.0` | Flask · psycopg 3 · requests | 8080 | counters in memory (owns the `orders` **database**) |
| [`payment/`](payment/) | `cloudprakhargupta/ecommerce:payment-1.0.0` | Flask | 8080 | counters in memory |
| — | `postgres:17.5-alpine` | PostgreSQL 17 | 5432 | **products, orders** |
| — | `redis:8.2.9-alpine` | Redis 8 | 6379 | **carts** (TTL) |

### The call graph — the whole point of this project

```
browser → storefront ─┬→ catalog ──→ postgres (db: catalog)
                      ├→ cart ─────→ redis
                      └→ order ─┬──→ postgres (db: orders)
                                └──→ payment      ← the ONLY caller
```

`payment` is called by exactly one service. Nothing else should ever reach it, and after stage 15 nothing can —
which `payment`'s own `/whoami` counter proves.

---

## API surface

| Service | Method | Path | Purpose |
|---|---|---|---|
| storefront | `GET` | `/` | The shop UI |
| storefront | — | `/api/catalog/*`, `/api/cart/*`, `/api/orders` | Server-side proxy to the three backends |
| catalog | `GET` | `/api/catalog/products` | All products |
| catalog | `GET` | `/api/catalog/products/<sku>` | One product |
| cart | `GET` | `/api/cart/<session>` | Basket + remaining TTL |
| cart | `POST` | `/api/cart/<session>` | Add an item (`{sku, name, price_cents, quantity}`) |
| cart | `DELETE` | `/api/cart/<session>` | Clear the basket |
| order | `POST` | `/api/orders` | Checkout: authorise payment, then persist |
| order | `GET` | `/api/orders` | Latest 20 orders |
| payment | `POST` | `/api/payments/authorize` | Authorise `{amount_cents}` |
| **all** | `GET` | `/livez` | **Liveness** — the process only, never a dependency |
| **all** | `GET` | `/healthz` | **Readiness** — this service's *hard* dependencies |
| **all** | `GET` | `/whoami` | Pod name + whether each upstream is reachable **from this pod** |

> `/whoami` is the debugging tool of this project. With five services and a default-deny NetworkPolicy, "which hop
> is blocked?" is the only question that matters, and this endpoint answers it without exec-ing into anything.

### Readiness is not the same everywhere — on purpose

| Service | `/healthz` checks | Why |
|---|---|---|
| `storefront` | **nothing** | If it called the three APIs, one slow catalogue would pull the whole UI out of the load balancer — a partial outage becoming a total one |
| `catalog` | PostgreSQL | It cannot serve a catalogue without it |
| `cart` | Redis | Redis *is* the cart |
| `order` | PostgreSQL only — **not** `payment` | A payment outage must break checkout, not remove every order pod from the ALB |
| `payment` | nothing | It has no dependencies — and note it does **not** get slower under `PAYMENT_LATENCY_MS`, which is exactly why a slow service is hard to find |

---

## Run it locally with Docker first

Prove the application works before Kubernetes is involved. Every command below was run to produce the output shown.

```bash
docker network create ecom-test
docker run -d --name pg --network ecom-test \
  -e POSTGRES_USER=ecommerce -e POSTGRES_PASSWORD=devpw -e POSTGRES_DB=catalog postgres:17.5-alpine
docker run -d --name rd --network ecom-test redis:8.2.9-alpine redis-server --requirepass rpw

# `order` owns a SEPARATE database inside the same server — the ownership boundary.
until docker exec pg pg_isready -U ecommerce -d catalog; do sleep 2; done
docker exec pg psql -U ecommerce -d catalog -c 'CREATE DATABASE orders'

for s in catalog cart payment order storefront; do docker build -t "ecom-test/$s:dev" "$s"; done

docker run -d --name catalog --network ecom-test \
  -e POSTGRES_HOST=pg -e POSTGRES_DB=catalog -e POSTGRES_PASSWORD=devpw ecom-test/catalog:dev
docker run -d --name payment --network ecom-test ecom-test/payment:dev
docker run -d --name cart --network ecom-test \
  -e REDIS_HOST=rd -e REDIS_PASSWORD=rpw ecom-test/cart:dev
docker run -d --name order --network ecom-test \
  -e POSTGRES_HOST=pg -e POSTGRES_DB=orders -e POSTGRES_PASSWORD=devpw \
  -e PAYMENT_URL=http://payment:8080 ecom-test/order:dev
docker run -d --name storefront --network ecom-test -p 18080:8080 \
  -e CATALOG_URL=http://catalog:8080 -e CART_URL=http://cart:8080 -e ORDER_URL=http://order:8080 \
  ecom-test/storefront:dev
sleep 12

open http://localhost:18080        # xdg-open on Linux
```

**Check the fan-out works:**

```bash
curl -s localhost:18080/whoami | python3 -m json.tool
```

```json
{
    "dependencies": {
        "cart":    {"error": null, "reachable": true, "url": "http://cart:8080"},
        "catalog": {"error": null, "reachable": true, "url": "http://catalog:8080"},
        "orders":  {"error": null, "reachable": true, "url": "http://order:8080"}
    },
    "pod": "unknown",
    "service": "storefront"
}
```

▸ `"pod": "unknown"` is correct here. `POD_NAME` comes from the **Downward API**, which only exists in Kubernetes.

**Do a whole checkout:**

```bash
curl -s -X POST localhost:18080/api/cart/test-session -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-1001","name":"Mechanical keyboard","price_cents":8900,"quantity":2}'
ITEMS=$(curl -s localhost:18080/api/cart/test-session | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["items"]))')
curl -s -X POST localhost:18080/api/orders -H 'Content-Type: application/json' \
  -d "{\"session\":\"test-session\",\"items\":$ITEMS}" | python3 -m json.tool
```

```json
{
    "created_at": "2026-09-19T06:03:02.721934+00:00",
    "id": 1,
    "payment_ref": "pay_818704e7a12c",
    "session": "test-session",
    "total_cents": 30700
}
```

**See that only `order` ever called `payment`:**

```bash
docker run --rm --network ecom-test curlimages/curl:8.10.1 -s http://payment:8080/whoami
```

```json
{"service":"payment","stats":{"authorized":1,"callers_seen":{"order":1},"declined":0}, …}
```

▸ `callers_seen` is the evidence stage 15 uses. Right now *any* container on this network could add itself to that
list — which is the problem a NetworkPolicy solves.

**Watch the advisory lock do its job** (two gunicorn workers migrate at once):

```bash
docker logs catalog 2>&1 | grep -E 'migration lock|schema up to date'
```

```
level=INFO … msg=waiting for migration lock id=4040001
level=INFO … msg=schema up to date products=5
level=INFO … msg=waiting for migration lock id=4040001
level=INFO … msg=schema up to date products=5
```

▸ Two workers, two attempts, one winner, no error. That lock is why stage 11 can move migration into an init
container without the race changing.

**See a dependency failure name itself:**

```bash
docker stop payment
curl -s -X POST localhost:18080/api/orders -H 'Content-Type: application/json' \
  -d "{\"session\":\"test-session\",\"items\":$ITEMS}" | python3 -m json.tool
docker start payment
```

```json
{
    "error": "cannot reach payment at http://payment:8080",
    "detail": "… Failed to resolve 'payment' …",
    "service": "order"
}
```

> ⚠️ **This one differs in Kubernetes, and the difference matters.** Stopping a *container* removes its name from
> Docker's embedded DNS, so you get a **resolution** error. In Kubernetes the Service and its ClusterIP survive the
> pod, so the same break gives you **connection refused** (or a timeout) instead — the name still resolves, there
> is just nothing behind it. Expect `Name or service not known` only when the **Service** is missing, which is
> exactly the stage 03 → 04 failure.

**Make it slow instead of down — the cascading failure:**

```bash
docker rm -f payment
docker run -d --name payment --network ecom-test -e PAYMENT_LATENCY_MS=8000 ecom-test/payment:dev
sleep 3
time curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:18080/api/orders \
  -H 'Content-Type: application/json' -d "{\"session\":\"test-session\",\"items\":$ITEMS}"
```

▸ `payment` still passes every health check — it is not down, it is *late*. `order` gives up after
`UPSTREAM_TIMEOUT_SECONDS` and returns a 502 naming it. Remove that timeout and the whole storefront hangs
instead. That is the gap this project hands to **Project 05**.

**Clean up:**

```bash
docker rm -f pg rd catalog cart payment order storefront && docker network rm ecom-test
```

---

## Build for the cluster

```bash
docker login
../scripts/build-images.sh
# or elsewhere:  IMAGE_REPO=<acct>.dkr.ecr.us-east-1.amazonaws.com/ecommerce ../scripts/build-images.sh
```

EKS nodes are EC2 instances that can only run images they can **pull** from a registry — there is no `kind load`
on a managed cluster. Publishing elsewhere means changing `images[].newName` in
`manifests/19-final/kustomization.yaml`, never the manifests.

---

## Configuration contract

Everything comes from the environment. **The images never change between stages; only the environment does.**

| Variable | Read by | Default | Source, by stage |
|---|---|---|---|
| `CATALOG_URL`, `CART_URL`, `ORDER_URL` | storefront | `http://127.0.0.1:8080` | 03 literal names → 05 ConfigMap |
| `PAYMENT_URL` | order | `http://127.0.0.1:8080` | 03 `http://payment:8080` → 05 ConfigMap |
| `POSTGRES_HOST` / `PORT` / `USER` | catalog, order | `127.0.0.1` / `5432` / `ecommerce` | 03 literal → 05 ConfigMap |
| `POSTGRES_DB` | catalog / order | `catalog` / `orders` | **Different per service** — the ownership boundary |
| `POSTGRES_PASSWORD` | catalog, order, postgres | *(empty)* | 03 plaintext → **06 Secret** |
| `REDIS_HOST` / `REDIS_PORT` | cart | `127.0.0.1` / `6379` | 03 literal → 05 ConfigMap |
| `REDIS_PASSWORD` | cart, redis | *(empty)* | 03 plaintext → **06 Secret** |
| `CART_TTL_SECONDS` | cart | `1800` | 05 ConfigMap |
| `PAYMENT_LATENCY_MS` | payment | `0` | 05 ConfigMap — the cascading-failure dial |
| `PAYMENT_FAIL_RATE` | payment | `0` | 05 ConfigMap |
| `UPSTREAM_TIMEOUT_SECONDS` | storefront, order | `3` | 05 ConfigMap — the fix for that failure |
| `RUN_MIGRATIONS` | catalog, order | `true` | 11: `false` (an init container migrates) |
| `POD_NAME` | all | `unknown` | Downward API |

---

## Design notes

**Short-lived connections everywhere.** Every PostgreSQL, Redis and HTTP call opens a new connection. A pool
would pin to one backend pod and hide both load balancing and policy changes; this way a NetworkPolicy you just
applied shows up on the very next request instead of never.

**`order` copies prices onto the order row.** It stores `items` as JSONB rather than joining into the catalogue,
because products belong to `catalog`. A price change next week must not silently rewrite last week's orders. That
is also why there is no foreign key across the boundary.

**Two advisory lock IDs, not one.** `catalog` uses `4040001` and `order` uses `4040002`. They share a PostgreSQL
*server* but own different *databases*; a shared lock id would make them queue behind each other for no reason.

**One gunicorn worker in `payment` and `order`.** Their `/whoami` counters — `callers_seen`, `payment_failures` —
live in process memory, and those counters are evidence used by the failure labs. Two workers would split the
evidence. `storefront`, `catalog` and `cart` hold nothing per-process and run two.

**Threads, not processes, in `payment`.** `PAYMENT_LATENCY_MS` makes each request sleep. Eight threads mean the
service goes *slow* rather than *unavailable*, which is the realistic and much harder-to-diagnose failure.

---

## Dockerfile rules in this repo

| Rule | Why |
|---|---|
| Two-stage build | No compilers or pip cache in the runtime image |
| Non-root user (UID 10001) | Project 07 enforces `runAsNonRoot`; nothing has to change then |
| Explicit tags, never `:latest` | A rollback must mean something |
| Pinned dependencies | A rebuilt image behaves like the tested one |
| gunicorn, not Flask's dev server | Graceful SIGTERM handling |
| Named container port `http` | Services, probes and the ALB reference the name |
