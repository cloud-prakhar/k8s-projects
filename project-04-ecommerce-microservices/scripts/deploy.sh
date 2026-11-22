#!/usr/bin/env bash
# Deploys Project 04 to its FINAL state on an EKS cluster.
#
# The teaching stages (literal env, mutable ConfigMap, Deployment versions of
# the datastores, stand-alone PVCs, policies applied one at a time) are applied
# by hand during the lesson. This script applies only the end state —
# manifests/19-final — through Kustomize, because the final ConfigMap is
# GENERATED there.
#
# Everything it does is written out in ./manual-steps.md Parts 1 and 3.
# Idempotent: safe to run repeatedly.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kubernetes-lab}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
LBC_CHART_VERSION="${LBC_CHART_VERSION:-3.5.0}"
NAMESPACE="ecommerce"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run() { echo "+ $*"; "$@"; }
die() { echo "❌ $*" >&2; exit 1; }

echo "=== 0. Are we pointed at the right cluster? ==="
# kubectl acts on whatever the CURRENT context is. With a production cluster in
# the same kubeconfig, this is the most important check in the file.
ctx=$(kubectl config current-context 2>/dev/null) || die "no current kube-context"
echo "  context: ${ctx}"
provider=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)
[[ "${provider}" == aws://* ]] || die "nodes are not EC2 instances (providerID='${provider}') — this project targets EKS"
[[ "${ctx}" == *"${CLUSTER_NAME}"* ]] || die "context '${ctx}' does not look like cluster '${CLUSTER_NAME}'"

echo ""
echo "=== 1. Prerequisite — NetworkPolicy ENFORCEMENT ==="
# Without the VPC CNI network policy agent, every policy in stage 15 is
# accepted and silently ignored. clusters/eks-advanced.yaml enables it.
containers=$(kubectl get daemonset aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[*].name}')
[[ "${containers}" == *aws-eks-nodeagent* ]] \
  || die "aws-node has no aws-eks-nodeagent container — set enableNetworkPolicy: \"true\" on the vpc-cni add-on (clusters/eks-advanced.yaml)"
kubectl get crd policyendpoints.networking.k8s.aws >/dev/null 2>&1 || die "PolicyEndpoint CRD missing"
echo "  ✅ network policy agent running"

echo ""
echo "=== 2. Prerequisite — the EBS CSI driver ==="
kubectl get csidriver ebs.csi.aws.com >/dev/null 2>&1 \
  || die "CSIDriver ebs.csi.aws.com missing — install the aws-ebs-csi-driver add-on"
echo "  ✅ ebs.csi.aws.com"

echo ""
echo "=== 3. Prerequisite — the AWS Load Balancer Controller ==="
if kubectl get deployment aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  echo "  already installed — skipping"
else
  command -v helm >/dev/null || die "helm is required to install the controller"
  kubectl get serviceaccount aws-load-balancer-controller -n kube-system >/dev/null 2>&1 \
    || die "ServiceAccount kube-system/aws-load-balancer-controller missing — its Pod Identity association comes from clusters/eks-advanced.yaml"
  vpc_id=$(aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" \
             --query cluster.resourcesVpcConfig.vpcId --output text)
  run helm repo add eks https://aws.github.io/eks-charts
  run helm repo update eks
  run helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version "${LBC_CHART_VERSION}" --namespace kube-system \
    --set clusterName="${CLUSTER_NAME}" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region="${AWS_REGION}" \
    --set vpcId="${vpc_id}" \
    --wait --timeout 5m
fi
kubectl get ingressclass alb >/dev/null 2>&1 || die "IngressClass alb missing after install"
echo "  ✅ IngressClass/alb"

echo ""
echo "=== 4. Who may reach the load balancer ==="
ALLOWED_CIDR="${ALLOWED_CIDR:-$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32}"
echo "  alb.ingress.kubernetes.io/inbound-cidrs = ${ALLOWED_CIDR}"

echo ""
echo "=== 5. Render and apply the final state (stage 19) ==="
# Only the Ingress annotation line is rewritten: the NetworkPolicy ipBlock uses
# the key `cidr:`, which this pattern does not match.
rendered=$(kubectl kustomize "${PROJECT_DIR}/manifests/19-final")
echo "+ kubectl kustomize manifests/19-final | sed inbound-cidrs | kubectl apply -f -"
sed "s#inbound-cidrs: 0.0.0.0/0#inbound-cidrs: ${ALLOWED_CIDR}#" <<< "${rendered}" | kubectl apply -f -

echo ""
echo "=== 6. Wait for the datastores, then the services ==="
run kubectl rollout status statefulset/postgres -n "${NAMESPACE}" --timeout=600s
run kubectl rollout status statefulset/redis -n "${NAMESPACE}" --timeout=600s
for d in payment catalog cart order storefront; do
  run kubectl rollout status "deployment/${d}" -n "${NAMESPACE}" --timeout=600s
done

echo ""
echo "=== 7. Wait for the ALB ==="
host=""
for _ in $(seq 1 36); do
  host=$(kubectl get ingress ecommerce-ingress -n "${NAMESPACE}" \
           -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "${host}" ]] && break
  sleep 10
done
[[ -n "${host}" ]] || die "no ALB hostname after 6 minutes — kubectl describe ingress ecommerce-ingress -n ${NAMESPACE}"

run kubectl get statefulsets,deployments,pvc,ingress,networkpolicies -n "${NAMESPACE}"

cat <<MSG

Deployed. The ALB hostname is:
  ${host}

Give it a minute or two for DNS and target health. Then:
  ./scripts/validate.sh
  open http://${host}/

💰 The ALB and two EBS volumes bill from now. When you are done:
  ./scripts/cleanup.sh
MSG
