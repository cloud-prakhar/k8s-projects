"""Schema migrations, applied in order, recorded in `schema_migrations`.

Two things make this safe to run from many places at once — which matters,
because in Kubernetes "at once" is the default:

1. A PostgreSQL ADVISORY LOCK. Every replica's API process (stages 03–09) and
   every pod's init container (stage 11) runs this code. They all start at the
   same moment. The lock makes them queue: the first applies the migrations,
   the rest wait, then find nothing left to do.

2. A record of what ran. `CREATE TABLE IF NOT EXISTS` is idempotent; most real
   migrations (`ALTER TABLE … ADD COLUMN`) are not. The version table is what
   lets a non-idempotent step run exactly once.

Without the lock, two pods reading `schema_migrations` in the same instant both
see version 2 missing, both run it, and the second one crashes.
"""

import logging
import time

import psycopg

log = logging.getLogger("migrations")

# Any 64-bit number, as long as every migrator agrees on it.
LOCK_ID = 7_303_2026

MIGRATIONS = [
    (
        "001_create_links",
        """
        CREATE TABLE IF NOT EXISTS links (
            code        TEXT PRIMARY KEY,
            target_url  TEXT NOT NULL,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """,
    ),
    (
        "002_links_created_at_idx",
        "CREATE INDEX IF NOT EXISTS links_created_at_idx ON links (created_at DESC)",
    ),
]


def run(dsn: str, attempts: int = 60, delay: float = 2.0) -> bool:
    """Apply pending migrations. Retries while the database is unreachable.

    Bounded on purpose: a database that never appears must eventually fail
    loudly (a crash, an init container stuck in Init:Error) rather than hang.
    """
    for attempt in range(1, attempts + 1):
        try:
            with psycopg.connect(dsn, autocommit=True) as conn:
                log.info("waiting for migration lock id=%s", LOCK_ID)
                conn.execute("SELECT pg_advisory_lock(%s)", (LOCK_ID,))
                try:
                    _apply(conn)
                finally:
                    conn.execute("SELECT pg_advisory_unlock(%s)", (LOCK_ID,))
            return True
        except psycopg.OperationalError as exc:
            first_line = str(exc).strip().splitlines()[0] if str(exc).strip() else "unknown"
            log.warning(
                "database not reachable attempt=%s/%s err=%s", attempt, attempts, first_line
            )
            time.sleep(delay)
    log.error("giving up: database never became reachable")
    return False


def _apply(conn: psycopg.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version     TEXT PRIMARY KEY,
            applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """
    )
    applied = {row[0] for row in conn.execute("SELECT version FROM schema_migrations")}
    for version, sql in MIGRATIONS:
        if version in applied:
            log.info("migration already applied version=%s", version)
            continue
        log.info("applying migration version=%s", version)
        with conn.transaction():
            conn.execute(sql)
            conn.execute("INSERT INTO schema_migrations (version) VALUES (%s)", (version,))
    log.info("schema up to date versions=%s", len(MIGRATIONS))
