#!/usr/bin/env bash
# Deploys every stage of this project, in the order the lessons introduce them.
# Idempotent: safe to re-run. Prints each command before running it — no magic.
set -euo pipefail

NAMESPACE="${NAMESPACE:-<namespace>}"
MANIFESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../manifests" && pwd)"

run() { echo "+ $*"; "$@"; }

# Stages are listed explicitly rather than globbed, so the deploy order is
# visible and matches the teaching order. Delete stages this project skips.
STAGES=(
  00-namespace
  03-deployments
  04-services
  05-configmaps
  06-secrets
  07-storage
  08-statefulsets
  09-ingress
  11-health-checks
  12-resources
  13-hpa
  14-pdb
  15-security
)
# Note: 01-pods and 02-replicasets are teaching stages only — they are applied
# by hand during the lesson and superseded by 03-deployments.

for stage in "${STAGES[@]}"; do
  [[ -d "$MANIFESTS/$stage" ]] || { echo "-- skip $stage (not in this project)"; continue; }
  echo ""
  echo "=== Stage $stage ==="
  run kubectl apply -f "$MANIFESTS/$stage/"

  # Let each stage settle before the next one depends on it.
  if [[ "$stage" == "00-namespace" ]]; then
    run kubectl get namespace "$NAMESPACE"
  fi
done

echo ""
echo "=== Waiting for workloads to become Ready ==="
run kubectl wait --for=condition=available --timeout=180s \
  deployment --all -n "$NAMESPACE"

echo ""
run kubectl get all -n "$NAMESPACE"
echo ""
echo "Deployed. Validate with: ./scripts/validate.sh"
