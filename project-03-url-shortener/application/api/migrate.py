"""Run the schema migrations and exit. Used by the init container in stage 11.

Exit code is the contract with Kubernetes: 0 lets the pod's app container start,
anything else makes the kubelet retry the init container and the pod shows
`Init:Error` / `Init:CrashLoopBackOff` instead of a half-started application.
"""

import logging
import sys

import migrations
import settings

logging.basicConfig(
    level=logging.INFO,
    format="level=%(levelname)s pod=" + settings.POD_NAME + " logger=%(name)s msg=%(message)s",
)

if __name__ == "__main__":
    sys.exit(0 if migrations.run(settings.DSN) else 1)
