#!/usr/bin/env bash
# Asserts Project 01 is actually working. Exits non-zero on the first failure,
# so it is also the way to confirm you have repaired a failure lab.
#
# Explained step by step in ./manual-steps.md Part 4.
set -euo pipefail

NAMESPACE="${NAMESPACE:-task-tracker}"
FAILURES=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILURES=$((FAILURES + 1)); }

echo "=== 1. Namespace exists ==="
if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  pass "namespace/${NAMESPACE}"
else
  fail "namespace/${NAMESPACE} missing — run ./scripts/deploy.sh"
  exit 1
fi

echo "=== 2. Deployments fully available ==="
for d in task-api task-web; do
  want=$(kubectl get deploy "$d" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  got=$(kubectl get deploy "$d" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [[ "${got:-0}" == "$want" && "${want:-0}" != "0" ]] \
    && pass "deployment/$d ${got}/${want} ready" \
    || fail "deployment/$d ${got:-0}/${want:-0} ready"
done

echo "=== 3. Every Pod is Ready (not merely Running) ==="
# READY 0/1 with STATUS Running means the readiness probe is failing — the pod
# is alive and deliberately receiving no traffic.
notready=$(kubectl get pods -n "${NAMESPACE}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
  | grep -v ' True$' || true)
[[ -z "$notready" ]] && pass "all pods Ready" || fail "not Ready:
$notready"

echo "=== 4. Services have endpoints ==="
# The most common silent failure in Kubernetes: a Service whose selector
# matches nothing reports no error anywhere, it just refuses connections.
for svc in task-api task-web; do
  eps=$(kubectl get endpointslices -n "${NAMESPACE}" \
        -l "kubernetes.io/service-name=${svc}" \
        -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null || true)
  [[ -n "$eps" ]] && pass "svc/${svc} → ${eps}" \
                  || fail "svc/${svc} has NO endpoints (selector mismatch, or no Pod is Ready)"
done

echo "=== 5. The application actually answers ==="
# Run the check from INSIDE the cluster so it exercises CoreDNS, the Service,
# the EndpointSlice and both tiers — not just a port-forward to one Pod.
if kubectl run validate-curl-$$ --rm -i --restart=Never --quiet \
     --image=curlimages/curl:8.10.1 -n "${NAMESPACE}" -- \
     curl -fsS -m 10 http://task-web.${NAMESPACE}.svc.cluster.local/api/tasks >/dev/null 2>&1; then
  pass "GET /api/tasks through task-web → task-api"
else
  fail "app did not respond — check: kubectl logs deployment/task-web -n ${NAMESPACE}"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo "All checks passed."
else
  echo "${FAILURES} check(s) failed. Start with:"
  echo "  kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp | tail -20"
  exit 1
fi
