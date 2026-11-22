"""Schema for the `orders` database.

Imported by `app.py` (stages 03–09) and run as a one-shot by `migrate.py`
(stage 11's init container), so the schema can never drift between the two.

Note `items JSONB`: the order stores a COPY of what was bought, at the price
quoted at the time. It does not join into the catalogue. That is deliberate —
`catalog` owns products, `order` owns orders, and a price change next week must
not silently rewrite last week's orders.
"""

import logging
import time

import psycopg

log = logging.getLogger("migrations")

# Distinct from the catalog service's lock id: the two share a PostgreSQL server
# but own different databases, and a shared id would make them queue needlessly.
LOCK_ID = 4_040_002


def first_line(exc: Exception) -> str:
    text = str(exc).strip()
    return text.splitlines()[0][:200] if text else exc.__class__.__name__


def run(dsn: str, attempts: int = 30, delay: float = 2.0) -> bool:
    """Apply the schema, retrying while the database is unreachable. Bounded, so
    a database that never appears fails loudly instead of hanging."""
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
        CREATE TABLE IF NOT EXISTS orders (
            id          BIGSERIAL PRIMARY KEY,
            session     TEXT NOT NULL,
            total_cents INTEGER NOT NULL,
            payment_ref TEXT NOT NULL,
            items       JSONB NOT NULL,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS orders_created_at_idx ON orders (created_at DESC)"
    )
    log.info("schema up to date")
