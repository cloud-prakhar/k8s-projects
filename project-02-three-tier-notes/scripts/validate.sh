#!/usr/bin/env bash
# Asserts Project 02 is actually working. Exits non-zero on the first failure,
# so it is also the way to confirm you have repaired a failure lab.
#
# Explained step by step in ./manual-steps.md Part 4.
set -euo pipefail

NAMESPACE="${NAMESPACE:-notes-platform}"
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

echo "=== 2. Workloads fully available ==="
for d in notes-api notes-web; do
  want=$(kubectl get deploy "$d" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  got=$(kubectl get deploy "$d" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [[ "${got:-0}" == "$want" && "${want:-0}" != "0" ]] \
    && pass "deployment/$d ${got}/${want} ready" \
    || fail "deployment/$d ${got:-0}/${want:-0} ready"
done
sts_want=$(kubectl get sts postgres -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
sts_got=$(kubectl get sts postgres -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[[ "${sts_got:-0}" == "$sts_want" && "${sts_want:-0}" != "0" ]] \
  && pass "statefulset/postgres ${sts_got}/${sts_want} ready" \
  || fail "statefulset/postgres ${sts_got:-0}/${sts_want:-0} ready"

echo "=== 3. Storage is bound (not Pending) ==="
# A PVC stuck in Pending is the number one storage failure: no default
# StorageClass, an unsatisfiable size, or a provisioner that isn't running.
phase=$(kubectl get pvc postgres-data-postgres-0 -n "${NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ "$phase" == "Bound" ]]; then
  vol=$(kubectl get pvc postgres-data-postgres-0 -n "${NAMESPACE}" -o jsonpath='{.spec.volumeName}')
  pass "pvc/postgres-data-postgres-0 Bound → ${vol}"
else
  fail "pvc/postgres-data-postgres-0 is '${phase:-missing}', expected Bound"
fi

echo "=== 4. Every pod is Ready (not merely Running) ==="
# READY 0/1 with STATUS Running means a readiness probe is failing — the pod is
# alive and deliberately receiving no traffic.
notready=$(kubectl get pods -n "${NAMESPACE}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
  | grep -v ' True$' || true)
[[ -z "$notready" ]] && pass "all pods Ready" || fail "not Ready:
$notready"

echo "=== 5. Services have endpoints ==="
# The most common silent failure in Kubernetes: a Service whose selector matches
# nothing reports no error anywhere, it just refuses connections.
for svc in postgres postgres-headless notes-api notes-web; do
  eps=$(kubectl get endpointslices -n "${NAMESPACE}" \
        -l "kubernetes.io/service-name=${svc}" \
        -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null || true)
  [[ -n "$eps" ]] && pass "svc/${svc} → ${eps}" \
                  || fail "svc/${svc} has NO endpoints (selector mismatch, or no pod is Ready)"
done

echo "=== 6. The data is actually in PostgreSQL ==="
# Proves the whole chain end to end: the pod is up, the password from the Secret
# works, the volume is mounted, and the seed script ran.
if count=$(kubectl exec statefulset/postgres -n "${NAMESPACE}" -- \
      psql -U notes -d notes -tAc 'SELECT count(*) FROM notes' 2>/dev/null); then
  pass "postgres holds ${count//[[:space:]]/} note(s)"
else
  fail "could not query postgres — check: kubectl logs statefulset/postgres -n ${NAMESPACE}"
fi

echo "=== 7. The application answers, from inside the cluster ==="
# Run from INSIDE so it exercises CoreDNS, the Services, the EndpointSlices and
# all three tiers — not just a port-forward to one pod.
if kubectl run validate-curl-$$ --rm -i --restart=Never --quiet \
     --image=curlimages/curl:8.10.1 -n "${NAMESPACE}" -- \
     curl -fsS -m 10 "http://notes-web.${NAMESPACE}.svc.cluster.local/api/notes" >/dev/null 2>&1; then
  pass "GET /api/notes through notes-web → notes-api → postgres"
else
  fail "app did not respond — check: kubectl logs deployment/notes-web -n ${NAMESPACE}"
fi

echo "=== 8. The Ingress routes from outside the cluster ==="
# Host header, not DNS: the ingress controller matches on the Host header, so
# this works whether or not notes.local is in /etc/hosts.
if kubectl get ingress notes-ingress -n "${NAMESPACE}" >/dev/null 2>&1; then
  if curl -fsS -m 10 -H 'Host: notes.local' http://localhost/api/notes >/dev/null 2>&1; then
    pass "http://notes.local/api/notes via the ingress controller"
  else
    fail "ingress did not answer on localhost:80 — is the controller installed, and was the
     cluster created with clusters/kind-ingress.yaml (extraPortMappings)?"
  fi
else
  fail "ingress/notes-ingress missing"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo "All checks passed."
else
  echo "${FAILURES} check(s) failed. Start with:"
  echo "  kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp | tail -20"
  exit 1
fi
