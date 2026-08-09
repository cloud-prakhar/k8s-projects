#!/usr/bin/env bash
# Deploys Project 01 to its final state.
#
# Stages 01-pods and 02-replicasets are TEACHING artifacts — they are applied by
# hand during the lesson and superseded by 03-deployments, so this script skips
# them. Everything it does is written out in ./manual-steps.md Part 3.
#
# Idempotent: safe to run repeatedly.
set -euo pipefail

NAMESPACE="${NAMESPACE:-task-tracker}"
MANIFESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../manifests" && pwd)"

run() { echo "+ $*"; "$@"; }

echo "=== Stage 00 — Namespace ==="
run kubectl apply -f "${MANIFESTS}/00-namespace/namespace.yaml"

echo ""
echo "=== Stages 05, 06 — Configuration and credentials ==="
# Applied BEFORE the workloads that reference them, or the new Pods would sit in
# CreateContainerConfigError waiting for keys that don't exist yet.
run kubectl apply -f "${MANIFESTS}/05-configmaps/configmap.yaml"
run kubectl apply -f "${MANIFESTS}/06-secrets/secret.yaml"

echo ""
echo "=== Stages 03, 11 — Workloads (final versions, with probes) ==="
run kubectl apply -f "${MANIFESTS}/11-health-checks/task-api-deployment.yaml"
run kubectl apply -f "${MANIFESTS}/11-health-checks/task-web-deployment.yaml"

echo ""
echo "=== Stage 04 — Services ==="
run kubectl apply -f "${MANIFESTS}/04-services/task-api-service.yaml"
run kubectl apply -f "${MANIFESTS}/04-services/task-web-service.yaml"

echo ""
echo "=== Waiting for rollouts (blocks until Pods pass readiness) ==="
run kubectl rollout status deployment/task-api -n "${NAMESPACE}" --timeout=180s
run kubectl rollout status deployment/task-web -n "${NAMESPACE}" --timeout=180s

echo ""
run kubectl get all -n "${NAMESPACE}"

cat <<MSG

Deployed. Next:
  ./scripts/validate.sh
  kubectl port-forward svc/task-web 8080:80 -n ${NAMESPACE}
  open http://localhost:8080
MSG
