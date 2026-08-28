#!/usr/bin/env bash
# Deploys Project 02 to its final state.
#
# Stages 03 and 07's early experiments (hardcoded Pod IPs, emptyDir, hostPath)
# are TEACHING artifacts — applied by hand during the lesson and superseded
# later — so this script skips them and applies the final version of each
# object. Everything it does is written out in ./manual-steps.md Part 3.
#
# Idempotent: safe to run repeatedly.
set -euo pipefail

NAMESPACE="${NAMESPACE:-notes-platform}"
INGRESS_VERSION="${INGRESS_VERSION:-controller-v1.15.1}"
INSTALL_INGRESS="${INSTALL_INGRESS:-true}"
MANIFESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../manifests" && pwd)"

run() { echo "+ $*"; "$@"; }

echo "=== Prerequisite — the NGINX Ingress Controller ==="
# An Ingress object without a controller is inert: it is created successfully,
# reports no error, and routes nothing. This is CLUSTER-scoped software, not
# part of the application, which is why it is installed separately.
if kubectl get ingressclass nginx >/dev/null 2>&1; then
  echo "  ingressclass/nginx already present — skipping install"
else
  if [[ "${INSTALL_INGRESS}" == "true" ]]; then
    run kubectl apply -f \
      "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VERSION}/deploy/static/provider/kind/deploy.yaml"
    echo "  waiting for the controller to become Ready…"
    run kubectl wait --namespace ingress-nginx \
      --for=condition=Ready pod \
      --selector=app.kubernetes.io/component=controller \
      --timeout=180s
  else
    echo "  ⚠️  no ingress controller and INSTALL_INGRESS=false — the Ingress will do nothing"
  fi
fi

echo ""
echo "=== Stage 00 — Namespace ==="
run kubectl apply -f "${MANIFESTS}/00-namespace/namespace.yaml"

echo ""
echo "=== Stages 05, 06 — Configuration and credentials ==="
# Applied BEFORE the workloads that reference them, or the new pods would sit in
# CreateContainerConfigError waiting for keys that do not exist yet.
run kubectl apply -f "${MANIFESTS}/05-configmaps/configmap.yaml"
run kubectl apply -f "${MANIFESTS}/05-configmaps/postgres-init-configmap.yaml"
run kubectl apply -f "${MANIFESTS}/06-secrets/secret.yaml"

echo ""
echo "=== Stages 04, 08 — Services (including the headless one) ==="
# Services before workloads: the headless Service must exist before the
# StatefulSet's pods start, or their per-pod DNS names do not resolve during
# start-up. Creating a Service early is free — it simply has no endpoints yet.
run kubectl apply -f "${MANIFESTS}/04-services/postgres-service.yaml"
run kubectl apply -f "${MANIFESTS}/08-statefulsets/01-postgres-headless-service.yaml"
run kubectl apply -f "${MANIFESTS}/04-services/notes-api-service.yaml"
run kubectl apply -f "${MANIFESTS}/04-services/notes-web-service.yaml"

echo ""
echo "=== Stages 08, 11 — Database (StatefulSet, own volume, exec probes) ==="
run kubectl apply -f "${MANIFESTS}/11-health-checks/postgres-statefulset.yaml"
echo "  waiting for postgres-0 to be Ready before starting the API…"
# `rollout status` on a StatefulSet waits for every replica to be Ready.
run kubectl rollout status statefulset/postgres -n "${NAMESPACE}" --timeout=300s

echo ""
echo "=== Stages 03, 05, 06, 11 — Application tiers (final versions) ==="
run kubectl apply -f "${MANIFESTS}/11-health-checks/notes-api-deployment.yaml"
run kubectl apply -f "${MANIFESTS}/11-health-checks/notes-web-deployment.yaml"

echo ""
echo "=== Stage 09 — Ingress ==="
run kubectl apply -f "${MANIFESTS}/09-ingress/02-notes-ingress.yaml"

echo ""
echo "=== Waiting for rollouts (blocks until pods pass readiness) ==="
run kubectl rollout status deployment/notes-api -n "${NAMESPACE}" --timeout=300s
run kubectl rollout status deployment/notes-web -n "${NAMESPACE}" --timeout=300s

echo ""
run kubectl get all,pvc,ingress -n "${NAMESPACE}"

cat <<MSG

Deployed. Next:
  ./scripts/validate.sh

  # Add the hostname once, then open it in a browser:
  echo "127.0.0.1 notes.local" | sudo tee -a /etc/hosts
  open http://notes.local

  # No sudo? The Host header is all that matters:
  curl -H 'Host: notes.local' http://localhost/api/notes
MSG
