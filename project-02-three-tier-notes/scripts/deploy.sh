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
#
# The controller is the ONE piece of this project that differs per platform, and
# it differs because the platforms genuinely differ in how outside traffic gets
# in. ingress-nginx ships one manifest per provider; we pick it from the node's
# providerID rather than asking you which cluster you are on:
#
#   kind      → hostPort 80/443 on a node labelled ingress-ready=true
#   cloud     → a Service type LoadBalancer (EKS provisions an NLB for it)
#   baremetal → NodePort (kubeadm, or anything with no cloud controller)
#
# Everything AFTER this block is identical on all three.
detect_provider() {
  local pid
  pid=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)
  case "${pid}" in
    kind://*) echo kind ;;
    aws://*|azure://*|gce://*) echo cloud ;;
    *)        echo baremetal ;;
  esac
}
INGRESS_PROVIDER="${INGRESS_PROVIDER:-$(detect_provider)}"

if kubectl get ingressclass nginx >/dev/null 2>&1; then
  echo "  ingressclass/nginx already present — skipping install"
elif [[ "${INSTALL_INGRESS}" != "true" ]]; then
  echo "  ⚠️  no ingress controller and INSTALL_INGRESS=false — the Ingress will do nothing"
else
  echo "  provider: ${INGRESS_PROVIDER} (override with INGRESS_PROVIDER=kind|cloud|baremetal)"

  if [[ "${INGRESS_PROVIDER}" == "kind" ]]; then
    # The kind manifest pins the controller to a node labelled ingress-ready=true.
    # clusters/kind-ingress.yaml sets that label at creation time; a cluster made
    # any other way (Docker Desktop's built-in Kubernetes, for one) has not got
    # it, and the controller pod would sit Pending forever with no node to match.
    if [[ -z "$(kubectl get nodes -l ingress-ready=true -o name 2>/dev/null)" ]]; then
      node=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
      echo "  no node carries ingress-ready=true — labelling ${node}"
      run kubectl label node "${node}" ingress-ready=true --overwrite
    fi
  fi

  run kubectl apply -f \
    "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VERSION}/deploy/static/provider/${INGRESS_PROVIDER}/deploy.yaml"
  echo "  waiting for the controller to become Ready…"
  run kubectl wait --namespace ingress-nginx \
    --for=condition=Ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s
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

Reaching the app depends on how traffic enters YOUR cluster:

  # Works everywhere (Kind, kubeadm, EKS) — no DNS, no host ports, no sudo:
  kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80
  curl -H 'Host: notes.local' http://localhost:8080/api/notes

  # Kind built from clusters/kind-ingress.yaml (host port 80 mapped into the node):
  echo "127.0.0.1 notes.local" | sudo tee -a /etc/hosts
  curl http://notes.local/api/notes

  # EKS — the controller has a real load balancer in front of it:
  kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  # then point notes.local at that name, or send the Host header to it directly.
MSG
