#!/usr/bin/env bash
# Removes everything Project 02 created.
#
# Deleting the namespace covers all NAMESPACED objects — including the PVCs the
# StatefulSet created, which are NOT owned by the StatefulSet and would survive
# `kubectl delete statefulset` on its own.
#
# It does NOT cover cluster-scoped objects, and this project creates three:
#   • PersistentVolume notes-hostpath-demo   (stage 07 teaching artifact)
#   • StorageClass notes-platform-retain      (stage 07 teaching artifact)
#   • dynamically provisioned PVs             (deleted by their reclaim policy)
#
# Explained in ./manual-steps.md Part 5.
set -euo pipefail

NAMESPACE="${NAMESPACE:-notes-platform}"
run() { echo "+ $*"; "$@"; }

echo "=== 1. Delete the namespace (and everything in it, PVCs included) ==="
# Deletion is asynchronous — the namespace controller enumerates every resource
# type and deletes what it finds before the namespace itself disappears. Volumes
# are released here, which is what triggers step 2.
run kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true

echo ""
echo "=== 2. Cluster-scoped teaching artifacts ==="
run kubectl delete persistentvolume notes-hostpath-demo --ignore-not-found
run kubectl delete storageclass notes-platform-retain --ignore-not-found

echo ""
echo "=== 3. Orphaned PersistentVolumes ==="
# A PV whose class is Delete disappears with its claim. A PV whose class is
# Retain does NOT — it sits in phase `Released` holding disk forever until
# somebody deletes it. That is the reclaim policy doing exactly what it says,
# and it is why this check exists in every cleanup script from here on.
released=$(kubectl get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ -n "${released}" ]]; then
  echo "  Released volumes found — deleting:"
  while read -r pv; do [[ -n "$pv" ]] && run kubectl delete pv "$pv"; done <<< "${released}"
else
  echo "  none"
fi

echo ""
echo "=== 4. Verify ==="
if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "  ⚠️  namespace still present — check for finalizers:"
  echo "     kubectl get namespace ${NAMESPACE} -o jsonpath='{.spec.finalizers}'"
else
  echo "  ✅ namespace/${NAMESPACE} is gone"
fi
run kubectl get pv --no-headers 2>/dev/null || echo "  ✅ no persistent volumes"

cat <<MSG

The NGINX Ingress Controller is CLUSTER software and was left running — other
projects use it too. To remove it as well:
  kubectl delete namespace ingress-nginx

  # ⚠️ That delete HANGS on a cluster with no cloud load balancer (Kind, kubeadm).
  # The controller's Service is type LoadBalancer and carries the finalizer
  # service.kubernetes.io/load-balancer-cleanup, which only a cloud controller
  # manager removes — so nothing ever removes it and the namespace sits in
  # Terminating forever. Diagnose, then release it by hand:
  #   kubectl get ns ingress-nginx -o jsonpath='{.status.conditions}'   # "Some resources are remaining: services"
  #   kubectl patch svc ingress-nginx-controller -n ingress-nginx \\
  #     -p '{"metadata":{"finalizers":null}}' --type=merge
  # A finalizer is a promise that something will clean up an external resource.
  # If the thing that made the promise is not running, you must break it yourself.

Local build artifacts are still on your machine; that is intentional (rebuilding
is slow). To remove them too:
  docker rmi cloudprakhargupta/notes-app:api-1.0.0 cloudprakhargupta/notes-app:web-1.0.0
The images in the registry are left alone — deleting a published tag is a
registry-side action, not something a cleanup script should do behind your back.

To reset the entire environment:
  kind delete cluster --name kubernetes-lab     # Kind
  # kubeadm / EKS: the cluster outlives the project — the steps above are the cleanup.
MSG
