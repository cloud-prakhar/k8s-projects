"""Every setting the API reads, in one place, straight from the environment.

The image never changes between stages. Only the environment does — hardcoded
literals in stage 03, a ConfigMap in stage 05, an IMMUTABLE versioned ConfigMap
later in stage 05, Secrets in stage 06. Keeping every variable here makes the
contract between the image and the manifests readable in one screen.
"""

import os


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default) or default


APP_ENV = env("APP_ENV", "development")
LOG_LEVEL = env("LOG_LEVEL", "info")
POD_NAME = env("POD_NAME", "unknown")          # Downward API — which pod answered
CONFIG_VERSION = env("CONFIG_VERSION", "none")  # set by the ConfigMap itself

# --- PostgreSQL: the durable store. Every short link is a row. -------------
POSTGRES_HOST = env("POSTGRES_HOST", "127.0.0.1")
POSTGRES_PORT = env("POSTGRES_PORT", "5432")
POSTGRES_DB = env("POSTGRES_DB", "shortener")
POSTGRES_USER = env("POSTGRES_USER", "shortener")
POSTGRES_PASSWORD = env("POSTGRES_PASSWORD", "")

DSN = (
    f"host={POSTGRES_HOST} port={POSTGRES_PORT} dbname={POSTGRES_DB} "
    f"user={POSTGRES_USER} password={POSTGRES_PASSWORD} connect_timeout=3"
)

# --- Redis: the fast store. A cache in front of PostgreSQL, plus click counters.
# Two hosts, not one, and the split is the lesson of stage 08:
#   WRITE — must reach the PRIMARY. A replica refuses writes with READONLY.
#   READ  — any member will do, so a load-balanced Service is fine.
# Until stage 08 there is only one Redis, so both point at the same name.
REDIS_WRITE_HOST = env("REDIS_WRITE_HOST", "127.0.0.1")
REDIS_READ_HOST = env("REDIS_READ_HOST", REDIS_WRITE_HOST)
REDIS_PORT = int(env("REDIS_PORT", "6379"))
REDIS_PASSWORD = env("REDIS_PASSWORD", "")

# --- Behaviour ----------------------------------------------------------------
# CODE_LENGTH must be identical on every replica. Two replicas that disagree
# generate codes the other one rejects — the drift failure stage 05 demonstrates.
CODE_LENGTH = int(env("CODE_LENGTH", "6"))
CACHE_TTL_SECONDS = int(env("CACHE_TTL_SECONDS", "300"))
# Blank = build short URLs from the Host the request arrived on. Behind an ALB
# whose hostname does not exist until the Ingress is created, that is exactly
# what you want.
PUBLIC_BASE_URL = env("PUBLIC_BASE_URL", "").rstrip("/")
# Where click events are sent. A bare name — `analytics` — that stage 04 turns
# into an ExternalName Service pointing at another team's namespace.
ANALYTICS_URL = env("ANALYTICS_URL", "")

# Stage 11 moves migrations into an init container and turns this off.
RUN_MIGRATIONS = env("RUN_MIGRATIONS", "true").lower() == "true"
