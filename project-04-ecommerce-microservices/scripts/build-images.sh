#!/usr/bin/env bash
# Builds the five application images and pushes them to a container registry.
#
# WHY a registry: an EKS node is an EC2 instance with its own container runtime.
# It can only run images it can PULL. There is no `kind load` on a managed
# cluster — a registry is the only way in, and it behaves the same everywhere.
#
# PostgreSQL and Redis are NOT built: `postgres:17.5-alpine` and
# `redis:8.2.9-alpine` are public images the nodes pull from Docker Hub.
#
# Every step here is explained in ./manual-steps.md Part 2.
set -euo pipefail

# One repository, five images, told apart by tag prefix. ECR instead:
#   IMAGE_REPO=<acct>.dkr.ecr.<region>.amazonaws.com/ecommerce ./scripts/build-images.sh
IMAGE_REPO="${IMAGE_REPO:-cloudprakhargupta/ecommerce}"
TAG="${TAG:-1.0.0}"                        # never :latest
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../application" && pwd)"

SERVICES=(storefront catalog cart order payment)

run() { echo "+ $*"; "$@"; }

echo "Publishing to ${IMAGE_REPO}"
echo "You must be authenticated first:  docker login"
echo "(ECR:  aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <registry>)"

for component in "${SERVICES[@]}"; do
  image="${IMAGE_REPO}:${component}-${TAG}"
  echo ""
  echo "=== Building ${image} ==="
  run docker build -t "${image}" "${APP_DIR}/${component}"
  echo "=== Pushing ${image} ==="
  run docker push "${image}"
done

echo ""
echo "=== Verifying the registry really has them ==="
# "I built it" is not "the cluster can pull it". This asks the registry, and is
# the check that prevents a stage-03 ImagePullBackOff you would otherwise spend
# twenty minutes misdiagnosing as a cluster problem.
for component in "${SERVICES[@]}"; do
  run docker manifest inspect "${IMAGE_REPO}:${component}-${TAG}" >/dev/null
  echo "  ✅ ${IMAGE_REPO}:${component}-${TAG}"
done

cat <<MSG

Images published. Pushed under a different IMAGE_REPO? Change ONLY the
images: field in manifests/19-final/kustomization.yaml — never the manifests.

Want to see the application work before Kubernetes is involved?
  application/README.md has a plain-Docker run-through of the whole call graph,
  including the cascading failure a slow payment service causes.
MSG
