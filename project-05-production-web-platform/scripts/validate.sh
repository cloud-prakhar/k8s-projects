#!/usr/bin/env bash
# Asserts Project 05 is working: sized, probed, autoscaled, budgeted and
# serving through the ALB. Exits non-zero if any check fails.
#
# Explained step by step in ./manual-steps.md Part 4.
set -euo pipefail

NS="${NAMESPACE:-web-platform}"
FAILURES=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILURES=$((FAILURES + 1)); }

echo "=== 1. Namespace ==="
kubectl get namespace "${NS}" >/dev/null 2>&1 && pass "namespace/${NS}" || { fail "namespace missing"; exit 1; }

echo "=== 2. webapp available and Ready (probes + ALB readiness gates) ==="
want=$(kubectl get deploy webapp -n "${NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
got=$(kubectl get deploy webapp -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
[[ -n "$want" && "${got:-0}" == "$want" && "$want" -ge 3 ]] && pass "deployment/webapp ${got}/${want}" \
  || fail "deployment/webapp ${got:-0}/${want:-?} (expected ≥3 ready)"
notready=$(kubectl get pods -n "${NS}" -l app.kubernetes.io/name=webapp \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -v ' True$' || true)
[[ -z "$notready" ]] && pass "all webapp pods Ready" || fail "not Ready: $notready"

echo "=== 3. Resources: every webapp pod is Burstable with requests AND limits ==="
qos=$(kubectl get pods -n "${NS}" -l app.kubernetes.io/name=webapp -o jsonpath='{range .items[*]}{.status.qosClass}{"\n"}{end}' | sort -u)
[[ "$qos" == "Burstable" ]] && pass "QoS class Burstable" || fail "QoS classes: ${qos//$'\n'/ } (expected Burstable)"
req=$(kubectl get deploy webapp -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
lim=$(kubectl get deploy webapp -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')
[[ -n "$req" && -n "$lim" ]] && pass "requests.cpu=${req}, limits.memory=${lim}" || fail "requests/limits missing"
kubectl get limitrange web-platform-defaults -n "${NS}" >/dev/null 2>&1 && pass "LimitRange present" || fail "LimitRange missing"
kubectl get resourcequota web-platform-quota -n "${NS}" >/dev/null 2>&1 && pass "ResourceQuota present" || fail "ResourceQuota missing"

echo "=== 4. Graceful shutdown configured ==="
pre=$(kubectl get deploy webapp -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.sleep.seconds}')
grace=$(kubectl get deploy webapp -n "${NS}" -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}')
[[ -n "$pre" && -n "$grace" && "$grace" -gt "$pre" ]] && pass "preStop sleep ${pre}s < grace ${grace}s" \
  || fail "preStop='${pre}' grace='${grace}' — preStop must exist and fit inside the grace period"

echo "=== 5. Metrics flow and the HPA can see them ==="
kubectl top pods -n "${NS}" -l app.kubernetes.io/name=webapp >/dev/null 2>&1 && pass "kubectl top pods" || fail "no pod metrics"
cur=""
for _ in $(seq 1 12); do
  cur=$(kubectl get hpa webapp-hpa -n "${NS}" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)
  [[ -n "$cur" ]] && break; sleep 10
done
[[ -n "$cur" ]] && pass "HPA sees CPU utilisation: ${cur}%" || fail "HPA shows no current metric (<unknown>) — requests set? metrics-server up?"
[[ -z "$(kubectl get deploy webapp -n "${NS}" -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | grep -o '"replicas"')" ]] \
  && pass "manifest does not set replicas (the HPA owns it)" || fail "applied manifest sets spec.replicas — it will fight the HPA"

echo "=== 6. PDB permits exactly one disruption ==="
allowed=$(kubectl get pdb webapp-pdb -n "${NS}" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || true)
[[ "$allowed" == "1" ]] && pass "webapp-pdb disruptionsAllowed=1" || fail "webapp-pdb disruptionsAllowed='${allowed}'"

echo "=== 7. Through the ALB ==="
host=$(kubectl get ingress web-platform-ingress -n "${NS}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -z "$host" ]]; then fail "no ALB hostname"; else
  ok=""
  for _ in $(seq 1 12); do
    curl -fsS -m 8 "http://${host}/api/info" 2>/dev/null | grep -q '"version"' && { ok=yes; break; }; sleep 10
  done
  [[ -n "$ok" ]] && pass "http://<alb>/api/info answered by webapp" \
    || fail "ALB did not answer (000 = IP not in inbound-cidrs / DNS; 503 = no healthy targets)"
  if [[ -n "$ok" ]]; then
    body=$(curl -fsS -m 8 "http://${host}/api/work?ms=50" || true)
    grep -q '"cpu_ms"' <<< "$body" && pass "/api/work burns CPU" || fail "/api/work failed"
  fi
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then echo "All checks passed."; else
  echo "${FAILURES} check(s) failed. Start with:"
  echo "  kubectl get events -n ${NS} --sort-by=.lastTimestamp | tail -20"; exit 1; fi
