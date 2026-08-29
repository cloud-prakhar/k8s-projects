#!/usr/bin/env bash
# Builds the two application images and pushes them to a container registry.
#
# WHY a registry and not a side-load: a cluster node has its own image store,
# separate from your laptop's Docker daemon. An image that only exists locally
# is invisible to the kubelet, which falls back to pulling from a registry and
# gives you ErrImagePull / ImagePullBackOff.
#
# There is a shortcut for each platform — `kind load docker-image` on Kind,
# `ctr -n k8s.io images import` on kubeadm, `docker save | minikube image load`
# on Minikube — but every one of them is different, and none of them exists on
# EKS. A registry is the ONE mechanism that behaves identically everywhere, so
# it is the one this repository teaches. On EKS you change nothing but IMAGE_REPO
# (point it at ECR); the manifests and every other command stay byte-identical.
#
# PostgreSQL is NOT built or pushed: `postgres:17.5-alpine` is a public image
# the kubelet pulls from Docker Hub like any other.
#
# Every step here is explained in ./manual-steps.md Part 2.
set -euo pipefail

# One repository, two images, distinguished by tag prefix. Override IMAGE_REPO
# to publish under your own account or to ECR:
#   IMAGE_REPO=<acct>.dkr.ecr.eu-west-1.amazonaws.com/notes-app ./scripts/build-images.sh
IMAGE_REPO="${IMAGE_REPO:-cloudprakhargupta/notes-app}"
TAG="${TAG:-1.0.0}"                       # never :latest
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../application" && pwd)"

run() { echo "+ $*"; "$@"; }

echo "Publishing to ${IMAGE_REPO}"
echo "You must be authenticated first:  docker login"
echo "(ECR:  aws ecr get-login-password | docker login --username AWS --password-stdin <registry>)"

for component in backend:api frontend:web; do
  dir="${component%%:*}"
  prefix="${component##*:}"
  image="${IMAGE_REPO}:${prefix}-${TAG}"

  echo ""
  echo "=== Building ${image} ==="
  run docker build -t "${image}" "${APP_DIR}/${dir}"

  echo "=== Pushing ${image} ==="
  run docker push "${image}"
done

cat <<MSG

Images published. The manifests reference them as:
  image: ${IMAGE_REPO}:api-${TAG}    # notes-api
  image: ${IMAGE_REPO}:web-${TAG}    # notes-web
  imagePullPolicy: IfNotPresent      # pull once per node, then reuse the cached copy

Pushed under a different IMAGE_REPO? Retarget the manifests without editing them:
  kubectl kustomize manifests/19-final | kubectl apply -f -
after setting the override in manifests/19-final/kustomization.yaml (images: field).
MSG
