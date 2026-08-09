#!/usr/bin/env bash
# Removes everything Project 01 created.
#
# Deleting the namespace covers all NAMESPACED objects. This project creates no
# cluster-scoped objects, but the check is here because later projects do (PVs,
# StorageClasses, ClusterRoles) and the habit matters.
#
# Explained in ./manual-steps.md Part 5.
set -euo pipefail

NAMESPACE="${NAMESPACE:-task-tracker}"
run() { echo "+ $*"; "$@"; }

echo "=== 1. Delete the namespace (and everything in it) ==="
# Deletion is asynchronous — the namespace controller enumerates every resource
# type and deletes what it finds before the namespace itself disappears.
run kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true

echo ""
echo "=== 2. Cluster-scoped leftovers (none expected in this project) ==="
run kubectl get pv --no-headers 2>/dev/null || echo "  no persistent volumes"

echo ""
echo "=== 3. Verify ==="
if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "  ⚠️  namespace still present — check for finalizers:"
  echo "     kubectl get namespace ${NAMESPACE} -o jsonpath='{.spec.finalizers}'"
else
  echo "  ✅ namespace/${NAMESPACE} is gone"
fi

cat <<MSG

Local images are still on your machine and in the cluster; that is intentional
(rebuilding is slow). To remove them too:
  docker rmi task-api:1.0.0 task-web:1.0.0

To reset the entire environment:
  kind delete cluster --name kubernetes-lab
MSG
