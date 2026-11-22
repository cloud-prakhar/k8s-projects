"""Create the orders schema and exit. Used by the init container in stage 11.

The EXIT CODE is the contract with Kubernetes: 0 lets the pod's app container
start; anything else makes the kubelet retry this container with back-off, and
the pod reports `Init:Error` / `Init:CrashLoopBackOff` rather than starting a
service that would fail every checkout against a missing table.
"""

import logging
import os
import sys

import migrations

POD_NAME = os.environ.get("POD_NAME", "unknown")

logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + POD_NAME + " svc=order-migrate msg=%(message)s",
)


def dsn() -> str:
    def env(key: str, default: str = "") -> str:
        return os.environ.get(key, default) or default

    return (
        f"host={env('POSTGRES_HOST', '127.0.0.1')} port={env('POSTGRES_PORT', '5432')} "
        f"dbname={env('POSTGRES_DB', 'orders')} user={env('POSTGRES_USER', 'ecommerce')} "
        f"password={env('POSTGRES_PASSWORD', '')} connect_timeout=3"
    )


if __name__ == "__main__":
    sys.exit(0 if migrations.run(dsn()) else 1)
