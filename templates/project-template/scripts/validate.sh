#!/usr/bin/env bash
# Asserts the project is actually working. Exits non-zero on the first failure
# so it can be used in CI or as a self-check after a failure lab.
set -euo pipefail

NAMESPACE="${NAMESPACE:-<namespace>}"
APP_HOST="${APP_HOST:-<app>.local}"
FAILURES=0

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILURES=$((FAILURES + 1)); }

echo "=== 1. Namespace exists ==="
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  && pass "namespace/$NAMESPACE" \
  || fail "namespace/$NAMESPACE missing — run ./scripts/deploy.sh"

echo "=== 2. All pods Ready ==="
NOT_READY=$(kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' \
  | grep -v ' Running$' || true)
[[ -z "$NOT_READY" ]] && pass "all pods Running" || fail "not Running:\n$NOT_READY"

echo "=== 3. Services have endpoints ==="
# A Service with no endpoints is the single most common silent failure:
# the selector doesn't match any Ready pod.
while read -r svc; do
  [[ -z "$svc" ]] && continue
  EP=$(kubectl get endpointslices -n "$NAMESPACE" \
        -l "kubernetes.io/service-name=$svc" \
        -o jsonpath='{.items[*].endpoints[*].addresses[*]}')
  [[ -n "$EP" ]] && pass "svc/$svc → $EP" || fail "svc/$svc has NO endpoints (selector mismatch?)"
done < <(kubectl get svc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

echo "=== 4. Application responds ==="
if curl -fsS -m 5 "http://${APP_HOST}/healthz" >/dev/null 2>&1; then
  pass "HTTP 200 from http://${APP_HOST}/healthz"
else
  fail "no healthy response from http://${APP_HOST}/healthz (Ingress? /etc/hosts? controller?)"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo "All checks passed."
else
  echo "$FAILURES check(s) failed. Start with: kubectl get events -n $NAMESPACE --sort-by=.lastTimestamp"
  exit 1
fi
