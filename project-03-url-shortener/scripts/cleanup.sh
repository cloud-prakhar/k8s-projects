#!/usr/bin/env bash
# Removes everything Project 03 created — in Kubernetes AND in AWS.
#
# ORDER MATTERS on EKS. Two controllers created real AWS resources on your
# behalf, and only they know how to delete them:
#
#   Ingress  → AWS Load Balancer Controller → ALB, target groups, security groups
#   PVCs     → EBS CSI driver               → EBS volumes
#
# Delete the Ingress while the controller is running and it removes the ALB.
# Remove the controller (or the whole cluster) first and the ALB is orphaned —
# still billing, with nothing left in the cluster that knows it exists.
#
# Explained in ./manual-steps.md Part 5.
set -euo pipefail

NS="url-shortener"
CLUSTER_NAME="${CLUSTER_NAME:-kubernetes-lab}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
run() { echo "+ $*"; "$@"; }

echo "=== 1. Delete the Ingress FIRST, and wait for the ALB to go ==="
# The Ingress carries the finalizer ingress.k8s.aws/resources. `delete --wait`
# blocks until the controller has deleted the ALB and removed that finalizer.
run kubectl delete ingress url-shortener-ingress -n "${NS}" --ignore-not-found --wait=true --timeout=300s

echo ""
echo "=== 2. Delete both namespaces (PVCs included → EBS volumes deleted) ==="
# StatefulSet PVCs are NOT owned by the StatefulSet, but they ARE in the
# namespace. Their StorageClass has reclaimPolicy: Delete, so the CSI driver
# deletes each EBS volume once its claim is gone.
run kubectl delete namespace "${NS}" analytics --ignore-not-found --wait=true --timeout=600s

echo ""
echo "=== 3. Cluster-scoped objects ==="
run kubectl delete storageclass url-shortener-gp3 --ignore-not-found

echo ""
echo "=== 4. Kubernetes-side leftovers ==="
released=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="url-shortener")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ -n "${released}" ]]; then
  echo "  PersistentVolumes still referencing ${NS} — waiting 60s for the CSI driver, then deleting:"
  sleep 60
  while read -r pv; do [[ -n "$pv" ]] && run kubectl delete pv "$pv" --ignore-not-found; done <<< "${released}"
else
  echo "  ✅ no PersistentVolumes left from ${NS}"
fi

echo ""
echo "=== 5. AWS-side orphan check (the part that costs money) ==="
if command -v aws >/dev/null; then
  # The EBS CSI driver tags every volume it creates with the claim's namespace.
  vols=$(aws ec2 describe-volumes --region "${AWS_REGION}" \
    --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=${NS}" \
    --query 'Volumes[].[VolumeId,State]' --output text 2>/dev/null || true)
  [[ -z "${vols}" ]] && echo "  ✅ no EBS volumes tagged for ${NS}" \
    || { echo "  ⚠️  EBS volumes still exist (state 'available' = orphaned, billing):"; echo "${vols}" | sed 's/^/     /';
         echo "     delete with: aws ec2 delete-volume --region ${AWS_REGION} --volume-id <id>"; }

  # The load balancer controller tags every ALB with its cluster and Ingress stack.
  lbs=$(aws resourcegroupstaggingapi get-resources --region "${AWS_REGION}" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" "Key=ingress.k8s.aws/stack,Values=${NS}/url-shortener-ingress" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)
  [[ -z "${lbs}" ]] && echo "  ✅ no ALB left for ${NS}/url-shortener-ingress" \
    || { echo "  ⚠️  ALB still exists:"; echo "${lbs}" | sed 's/^/     /'; }
else
  echo "  aws CLI not found — check the EC2 console for Volumes and Load Balancers manually"
fi

cat <<MSG

Project 03 is gone from the cluster. The CLUSTER is still running and still
billing (~\$0.20/hour). It is shared by later projects; to delete it:

  # 1. Make sure NO Ingress or LoadBalancer Service exists anywhere, or its
  #    load balancer is orphaned when the controller disappears:
  kubectl get ingress,svc -A | grep -Ei 'alb|LoadBalancer' || echo "none"
  # 2. Then delete the cluster (15 minutes):
  eksctl delete cluster --config-file clusters/eks-lab.yaml --disable-nodegroup-eviction

The images stay in the registry; deleting published tags is a registry-side
decision, not something a cleanup script should do behind your back.
MSG
