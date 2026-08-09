#!/usr/bin/env bash
# Removes everything this project created.
# Deleting the namespace is NOT enough: PersistentVolumes, StorageClasses,
# ClusterRoles, ClusterRoleBindings and PriorityClasses are cluster-scoped.
set -euo pipefail

NAMESPACE="${NAMESPACE:-<namespace>}"
PART_OF="${PART_OF:-<project>}"   # app.kubernetes.io/part-of label value

run() { echo "+ $*"; "$@"; }

echo "=== 1. Namespace-scoped objects ==="
run kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true

echo "=== 2. Cluster-scoped objects belonging to this project ==="
for kind in persistentvolume storageclass clusterrole clusterrolebinding priorityclass; do
  run kubectl delete "$kind" -l "app.kubernetes.io/part-of=$PART_OF" --ignore-not-found
done

echo "=== 3. Released PersistentVolumes ==="
# PVs with a Retain reclaim policy survive their PVC and stay 'Released'.
kubectl get pv --no-headers 2>/dev/null | grep -i released || echo "  none"

echo "=== 4. Verify nothing is left ==="
run kubectl get all -n "$NAMESPACE" || true
run kubectl get pv

echo ""
echo "Cleanup complete. To reset the whole environment instead:"
echo "  kind delete cluster --name kubernetes-lab"
