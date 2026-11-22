"""Schema and seed data for the `catalog` database.

Imported by `app.py` (stages 03–09, migrating from inside the serving process)
and run as a one-shot by `migrate.py` (stage 11's init container). Both paths
use the same code, so the schema can never drift between them.

A PostgreSQL ADVISORY LOCK makes it safe to run from many places at once —
which in Kubernetes is the default, not the exception. Two replicas start in the
same instant, both find the table missing, and without the lock both create it.
"""

import logging
import time

import psycopg

log = logging.getLogger("migrations")

# Any 64-bit number, as long as every migrator agrees on it. Distinct from the
# `order` service's lock id: they share a PostgreSQL server but own different
# databases, and a shared lock id would make them queue behind each other.
LOCK_ID = 4_040_001

SEED = [
    ("SKU-1001", "Mechanical keyboard", 8900),
    ("SKU-1002", "27-inch monitor", 24900),
    ("SKU-1003", "USB-C dock", 12900),
    ("SKU-1004", "Noise-cancelling headphones", 19900),
    ("SKU-1005", "Standing desk mat", 4900),
]


def first_line(exc: Exception) -> str:
    text = str(exc).strip()
    return text.splitlines()[0][:200] if text else exc.__class__.__name__


def run(dsn: str, attempts: int = 30, delay: float = 2.0) -> bool:
    """Apply the schema. Retries while the database is unreachable.

    Bounded on purpose: a database that never appears must eventually fail
    loudly — a crashed init container showing `Init:Error` — rather than hang
    forever looking healthy.
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
            log.warning(
                "database not reachable attempt=%s/%s err=%s", attempt, attempts, first_line(exc)
            )
            time.sleep(delay)
    log.error("giving up: database never became reachable")
    return False


def _apply(conn: psycopg.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS products (
            sku         TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            price_cents INTEGER NOT NULL
        )
        """
    )
    for sku, name, price in SEED:
        # ON CONFLICT DO NOTHING keeps this idempotent: every replica and every
        # restart runs it, and only the first one inserts anything.
        conn.execute(
            "INSERT INTO products (sku, name, price_cents) VALUES (%s, %s, %s) "
            "ON CONFLICT (sku) DO NOTHING",
            (sku, name, price),
        )
    log.info("schema up to date products=%s", len(SEED))
