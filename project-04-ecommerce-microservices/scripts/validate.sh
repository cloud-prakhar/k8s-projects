#!/usr/bin/env bash
# Asserts Project 04 is actually working — including that NetworkPolicy is
# ENFORCED, not merely present. Exits non-zero if any check fails, so it is also
# how you confirm a failure lab is repaired.
#
# Explained step by step in ./manual-steps.md Part 4.
set -euo pipefail

NS="${NAMESPACE:-ecommerce}"
FAILURES=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILURES=$((FAILURES + 1)); }

echo "=== 1. Namespace exists ==="
kubectl get namespace "${NS}" >/dev/null 2>&1 && pass "namespace/${NS}" \
  || { fail "namespace/${NS} missing — run ./scripts/deploy.sh"; exit 1; }

echo "=== 2. Workloads fully available ==="
for w in statefulset/postgres statefulset/redis deployment/storefront deployment/catalog \
         deployment/cart deployment/order deployment/payment; do
  want=$(kubectl get "$w" -n "${NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  got=$(kubectl get "$w" -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [[ -n "$want" && "$want" != "0" && "${got:-0}" == "$want" ]] \
    && pass "$w ${got}/${want}" || fail "$w ${got:-0}/${want:-?} ready"
done

echo "=== 3. Storage bound ==="
for pvc in postgres-data-postgres-0 redis-data-redis-0; do
  phase=$(kubectl get pvc "$pvc" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$phase" == "Bound" ]] && pass "pvc/$pvc Bound" || fail "pvc/$pvc is '${phase:-missing}'"
done

echo "=== 4. Every pod Ready (probes AND ALB readiness gates) ==="
notready=$(kubectl get pods -n "${NS}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
  | grep -v ' True$' || true)
[[ -z "$notready" ]] && pass "all pods Ready" || fail "not Ready:
$notready"

echo "=== 5. Services have endpoints ==="
for s in storefront catalog cart order payment postgres redis postgres-headless redis-headless; do
  eps=$(kubectl get endpointslices -n "${NS}" -l "kubernetes.io/service-name=$s" \
          -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null || true)
  [[ -n "$eps" ]] && pass "svc/$s → $eps" || fail "svc/$s has NO endpoints"
done

echo "=== 6. NetworkPolicies present, and the agent enforcing ==="
n=$(kubectl get networkpolicies -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
[[ "$n" -ge 10 ]] && pass "${n} NetworkPolicies" || fail "only ${n} NetworkPolicies (expected 10)"
kubectl get daemonset aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[*].name}' \
  | grep -q aws-eks-nodeagent && pass "aws-eks-nodeagent running" || fail "no network policy agent — policies are NOT enforced"

echo "=== 7. The allowed edge works: order → payment ==="
ok=$(kubectl exec -n "${NS}" deploy/order -c order -- python -c "
import urllib.request
try: print(urllib.request.urlopen('http://payment:8080/healthz', timeout=4).status)
except Exception as e: print('ERR', e)" 2>/dev/null || true)
[[ "$ok" == "200" ]] && pass "order reaches payment" || fail "order cannot reach payment: ${ok}"

echo "=== 8. The denied edges are denied ==="
# A pod the policies do not name must get NO RESPONSE — a dropped packet, not a
# refusal. Exit codes that cannot be confused with success:
#   pg_isready: 0 = accepting, 2 = no response (dropped)
#   wget -T:    0 = got a response, non-zero = timed out
out=$(kubectl run "validate-rogue-$$" --rm -i --restart=Never --quiet \
  --image=postgres:17.5-alpine -n "${NS}" -- \
  sh -c 'wget -q -T 4 -O /dev/null http://payment:8080/healthz; echo "pay=$?";
         pg_isready -h postgres -p 5432 -t 4 >/dev/null; echo "pg=$?"' 2>/dev/null || true)
# Require a POSITIVE non-zero result: an empty $out (the probe pod itself
# failed) must never count as "denied".
grep -qE 'pay=[1-9]' <<< "$out" && pass "rogue pod → payment gets no response" \
  || fail "rogue pod → payment: '${out//$'\n'/ }' — expected a non-zero wget exit (policy not enforced?)"
grep -q 'pg=2' <<< "$out" && pass "rogue pod → postgres gets no response (pg_isready exit 2)" \
  || fail "rogue pod → postgres: ${out//$'\n'/ } — expected pg=2"

echo "=== 9. End to end through the ALB: browse, basket, checkout ==="
host=$(kubectl get ingress ecommerce-ingress -n "${NS}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -z "$host" ]]; then
  fail "ingress has no ALB hostname"
else
  ready=""
  for _ in $(seq 1 12); do
    curl -fsS -m 8 "http://${host}/api/catalog/products" 2>/dev/null | grep -q '"sku"' && { ready=yes; break; }
    sleep 10
  done
  if [[ -z "$ready" ]]; then
    code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://${host}/api/catalog/products" || true)
    fail "ALB did not serve the catalogue (HTTP ${code:-timeout}). 000 = your IP not in inbound-cidrs / DNS not ready; 503 = no healthy targets"
  else
    pass "GET /api/catalog/products via the ALB"
    s="validate-$$"
    curl -fsS -m 8 -X POST "http://${host}/api/cart/${s}" -H 'Content-Type: application/json' \
      -d '{"sku":"SKU-1001","name":"Mechanical keyboard","price_cents":8900,"quantity":1}' >/dev/null \
      && pass "POST /api/cart → cart → redis" || fail "cart write failed"
    order=$(curl -sS -m 15 -X POST "http://${host}/api/orders" -H 'Content-Type: application/json' \
      -d "{\"session\":\"${s}\",\"items\":[{\"sku\":\"SKU-1001\",\"name\":\"k\",\"price_cents\":8900,\"quantity\":1}]}" || true)
    grep -q '"payment_ref"' <<< "$order" && pass "POST /api/orders → order → payment → postgres" \
      || fail "checkout failed: ${order:0:200}"
    code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://${host}/api/payments/authorize" || true)
    [[ "$code" == "404" ]] && pass "payment is not routable from the internet (404)" \
      || fail "payment path returned ${code} — expected 404"
    who=$(curl -s -m 8 -H 'Host: admin.shop.local' "http://${host}/whoami" || true)
    grep -q '"service":"order"' <<< "$who" && pass "host rule admin.shop.local routes to order" \
      || fail "host-based rule did not reach order"
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
