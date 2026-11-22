#!/usr/bin/env bash
# Removes everything Project 05 created — in Kubernetes AND in AWS.
# ORDER MATTERS: delete the Ingress first, while the load balancer controller is
# running, so it deletes the ALB. Explained in ./manual-steps.md Part 5.
set -euo pipefail

NS="web-platform"
CLUSTER_NAME="${CLUSTER_NAME:-kubernetes-lab}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
run() { echo "+ $*"; "$@"; }

echo "=== 1. Delete the Ingress FIRST, and wait for the ALB to go ==="
run kubectl delete ingress web-platform-ingress -n "${NS}" --ignore-not-found --wait=true --timeout=300s

echo ""
echo "=== 2. Uncordon anything a drain lab left cordoned ==="
# The stage 14 labs cordon and drain nodes. A node left unschedulable is not
# deleted by removing a namespace — and quietly halves the next project's capacity.
for n in $(kubectl get nodes -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{"\n"}{end}'); do
  run kubectl uncordon "$n"
done

echo ""
echo "=== 3. Delete the namespace ==="
run kubectl delete namespace "${NS}" --ignore-not-found --wait=true --timeout=600s

echo ""
echo "=== 4. AWS-side orphan check ==="
if command -v aws >/dev/null; then
  lbs=$(aws resourcegroupstaggingapi get-resources --region "${AWS_REGION}" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" "Key=ingress.k8s.aws/stack,Values=${NS}/web-platform-ingress" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)
  [[ -z "${lbs}" ]] && echo "  ✅ no ALB left for ${NS}/web-platform-ingress" || { echo "  ⚠️  ALB still exists:"; echo "${lbs}"; }
fi

cat <<MSG

Project 05 is gone from the cluster. The CLUSTER is still running (~\$0.22/hour).
To delete it — after making sure no Ingress or LoadBalancer Service remains:
  kubectl get ingress,svc -A | grep -Ei 'alb|LoadBalancer' || echo "none"
  eksctl delete cluster --config-file clusters/eks-advanced.yaml --disable-nodegroup-eviction
MSG
