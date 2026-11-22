#!/usr/bin/env bash
# Removes everything Project 04 created — in Kubernetes AND in AWS.
#
# ORDER MATTERS on EKS. Two controllers created real AWS resources, and only
# they know how to delete them:
#   Ingress → AWS Load Balancer Controller → ALB, target groups, security groups
#   PVCs    → EBS CSI driver               → EBS volumes
# Delete the Ingress while the controller runs and it removes the ALB. Remove
# the controller (or the cluster) first and the ALB is orphaned — still billing.
#
# Explained in ./manual-steps.md Part 5.
set -euo pipefail

NS="ecommerce"
CLUSTER_NAME="${CLUSTER_NAME:-kubernetes-lab}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
run() { echo "+ $*"; "$@"; }

echo "=== 1. Delete the Ingress FIRST, and wait for the ALB to go ==="
run kubectl delete ingress ecommerce-ingress -n "${NS}" --ignore-not-found --wait=true --timeout=300s

echo ""
echo "=== 2. Delete the namespace (PVCs included → EBS volumes deleted) ==="
run kubectl delete namespace "${NS}" --ignore-not-found --wait=true --timeout=600s

echo ""
echo "=== 3. Cluster-scoped objects ==="
run kubectl delete storageclass ecommerce-gp3 --ignore-not-found

echo ""
echo "=== 4. Kubernetes-side leftovers ==="
left=$(kubectl get pv -o jsonpath="{range .items[?(@.spec.claimRef.namespace==\"${NS}\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null || true)
if [[ -n "${left}" ]]; then
  echo "  PersistentVolumes still referencing ${NS} — waiting 60s for the CSI driver, then deleting:"
  sleep 60
  while read -r pv; do [[ -n "$pv" ]] && run kubectl delete pv "$pv" --ignore-not-found; done <<< "${left}"
else
  echo "  ✅ no PersistentVolumes left from ${NS}"
fi

echo ""
echo "=== 5. AWS-side orphan check (the part that costs money) ==="
if command -v aws >/dev/null; then
  vols=$(aws ec2 describe-volumes --region "${AWS_REGION}" \
    --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=${NS}" \
    --query 'Volumes[].[VolumeId,State]' --output text 2>/dev/null || true)
  [[ -z "${vols}" ]] && echo "  ✅ no EBS volumes tagged for ${NS}" \
    || { echo "  ⚠️  EBS volumes still exist ('available' = orphaned, billing):"; echo "${vols}" | sed 's/^/     /'; }
  lbs=$(aws resourcegroupstaggingapi get-resources --region "${AWS_REGION}" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" "Key=ingress.k8s.aws/stack,Values=${NS}/ecommerce-ingress" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)
  [[ -z "${lbs}" ]] && echo "  ✅ no ALB left for ${NS}/ecommerce-ingress" \
    || { echo "  ⚠️  ALB still exists:"; echo "${lbs}" | sed 's/^/     /'; }
else
  echo "  aws CLI not found — check the EC2 console for Volumes and Load Balancers manually"
fi

cat <<MSG

Project 04 is gone from the cluster. The CLUSTER is still running and billing
(~\$0.22/hour); Project 05 uses the same one. To delete it:

  kubectl get ingress,svc -A | grep -Ei 'alb|LoadBalancer' || echo "none"
  eksctl delete cluster --config-file clusters/eks-advanced.yaml --disable-nodegroup-eviction
MSG
