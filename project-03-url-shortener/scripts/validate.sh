#!/usr/bin/env bash
# Asserts Project 03 is actually working. Exits non-zero if any check fails, so
# it is also how you confirm a failure lab is repaired.
#
# Explained step by step in ./manual-steps.md Part 4.
set -euo pipefail

NS="${NAMESPACE:-url-shortener}"
FAILURES=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILURES=$((FAILURES + 1)); }

ready_count() {   # $1 kind/name, $2 namespace
  kubectl get "$1" -n "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true
}
want_count() {
  kubectl get "$1" -n "$2" -o jsonpath='{.spec.replicas}' 2>/dev/null || true
}

echo "=== 1. Namespaces exist ==="
for n in "${NS}" analytics; do
  kubectl get namespace "$n" >/dev/null 2>&1 && pass "namespace/$n" || { fail "namespace/$n missing — run ./scripts/deploy.sh"; exit 1; }
done

echo "=== 2. Workloads fully available ==="
for w in "statefulset/postgres ${NS}" "statefulset/redis ${NS}" "deployment/shortener-api ${NS}" \
         "deployment/shortener-web ${NS}" "deployment/analytics-collector analytics"; do
  set -- $w
  want=$(want_count "$1" "$2"); got=$(ready_count "$1" "$2")
  [[ -n "$want" && "$want" != "0" && "${got:-0}" == "$want" ]] \
    && pass "$1 ${got}/${want}" || fail "$1 ${got:-0}/${want:-?} ready"
done

echo "=== 3. Every claim is Bound to an EBS volume ==="
for pvc in postgres-data-postgres-0 redis-data-redis-0 redis-data-redis-1; do
  phase=$(kubectl get pvc "$pvc" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$phase" == "Bound" ]] && pass "pvc/$pvc Bound" \
    || fail "pvc/$pvc is '${phase:-missing}' — kubectl describe pvc $pvc -n ${NS}"
done

echo "=== 4. Every pod is Ready (probes AND ALB readiness gates) ==="
notready=$(kubectl get pods -n "${NS}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
  | grep -v ' True$' || true)
[[ -z "$notready" ]] && pass "all pods Ready" || fail "not Ready:
$notready"

echo "=== 5. Services have endpoints ==="
for s in "postgres ${NS}" "redis ${NS}" "redis-headless ${NS}" "shortener-api ${NS}" \
         "shortener-web ${NS}" "analytics-collector analytics"; do
  set -- $s
  eps=$(kubectl get endpointslices -n "$2" -l "kubernetes.io/service-name=$1" \
          -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null || true)
  [[ -n "$eps" ]] && pass "svc/$1 → $eps" || fail "svc/$1 has NO endpoints (selector mismatch, or nothing Ready)"
done

echo "=== 6. Redis roles follow the ordinals ==="
role0=$(kubectl exec -n "${NS}" redis-0 -c redis -- redis-cli info replication 2>/dev/null | tr -d '\r' | grep '^role:' || true)
link1=$(kubectl exec -n "${NS}" redis-1 -c redis -- redis-cli info replication 2>/dev/null | tr -d '\r' | grep -E '^master_link_status:' || true)
[[ "$role0" == "role:master" ]] && pass "redis-0 is the primary" || fail "redis-0 ${role0:-unreachable} — expected role:master"
[[ "$link1" == "master_link_status:up" ]] && pass "redis-1 replicating from redis-0" \
  || fail "redis-1 ${link1:-unreachable} — kubectl logs redis-1 -n ${NS}"

echo "=== 7. DNS names resolve the way the application needs ==="
# Resolved from INSIDE the API pod with the application's own resolver.
dns=$(kubectl exec -n "${NS}" deploy/shortener-api -c shortener-api -- python -c '
import socket
names = ["postgres", "redis", "redis-0.redis-headless", "analytics", "analytics-collector.analytics"]
for n in names:
    try:
        print(n, "ok", socket.gethostbyname(n))
    except OSError as e:
        print(n, "FAIL", e)
' 2>&1 || true)
while read -r name status rest; do
  [[ -z "$name" ]] && continue
  [[ "$status" == "ok" ]] && pass "$name → $rest" || fail "$name does not resolve: $rest"
done <<< "$dns"
ip0=$(kubectl get pod redis-0 -n "${NS}" -o jsonpath='{.status.podIP}')
grep -q "redis-0.redis-headless ok ${ip0}$" <<< "$dns" \
  && pass "redis-0.redis-headless is exactly redis-0's pod IP" \
  || fail "per-pod DNS does not match redis-0's IP (${ip0})"

echo "=== 8. The schema was migrated ==="
v=$(kubectl exec -n "${NS}" postgres-0 -c postgres -- psql -U shortener -d shortener -tAc \
      'SELECT count(*) FROM schema_migrations' 2>/dev/null | tr -d '[:space:]' || true)
[[ "${v:-0}" -ge 2 ]] && pass "schema_migrations has ${v} versions" || fail "schema not migrated — kubectl logs deploy/shortener-api -c migrate -n ${NS}"

echo "=== 9. End to end, inside the cluster: create, follow, count ==="
e2e=$(kubectl run "validate-e2e-$$" --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.10.1 -n "${NS}" -- sh -c '
  body=$(curl -fsS -m 10 -X POST http://shortener-web/api/links -H "Content-Type: application/json" -d "{\"url\":\"https://kubernetes.io/\"}")
  code=$(echo "$body" | sed -n "s/.*\"code\":\"\([A-Za-z0-9]*\)\".*/\1/p")
  curl -s -m 10 -o /dev/null -D - "http://shortener-api:8080/r/$code" | tr -d "\r" | grep -iE "^(HTTP|x-click-counted)"
' 2>/dev/null || true)
grep -q " 302" <<< "$e2e" && pass "POST /api/links then GET /r/<code> → 302" || fail "redirect did not work: ${e2e:-no output}"
grep -qi "x-click-counted: true" <<< "$e2e" && pass "click counted on the Redis primary" \
  || fail "click NOT counted — check REDIS_WRITE_HOST: curl …/api/info"

echo "=== 10. The ALB answers from outside ==="
host=$(kubectl get ingress url-shortener-ingress -n "${NS}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -z "$host" ]]; then
  fail "ingress has no ALB hostname — kubectl describe ingress url-shortener-ingress -n ${NS}"
else
  # Assert on the BODY: a 200 from something that is not our app proves nothing.
  ok=""
  for _ in 1 2 3 4 5 6; do
    if curl -fsS -m 10 "http://${host}/api/info" 2>/dev/null | grep -q '"config_version"'; then ok=yes; break; fi
    sleep 10
  done
  if [[ -n "$ok" ]]; then
    pass "http://<alb>/api/info answered by the shortener API"
  else
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://${host}/api/info" || true)
    fail "ALB did not answer correctly (HTTP ${code:-timeout}). 000/timeout = your IP is not in inbound-cidrs, or DNS not propagated yet; 503 = no healthy targets"
  fi
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo "All checks passed."
else
  echo "${FAILURES} check(s) failed. Start with:"
  echo "  kubectl get events -n ${NS} --sort-by=.lastTimestamp | tail -20"
  exit 1
fi
