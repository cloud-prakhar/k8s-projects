#!/usr/bin/env bash
# Builds the two application images and loads them into the Kind cluster.
#
# WHY the load step exists: a Kind "node" is a Docker container with its own
# image store. An image in your laptop's Docker daemon is invisible to it, so
# the kubelet falls back to pulling from a registry — where these images do not
# exist — and you get ErrImagePull / ImagePullBackOff.
#
# PostgreSQL is NOT built or loaded: `postgres:17.5-alpine` is a public image
# the kubelet pulls from Docker Hub like any other.
#
# Every step here is explained in ./manual-steps.md Part 2.
set -euo pipefail

CLUSTER="${CLUSTER:-kubernetes-lab}"
TAG="${TAG:-1.0.0}"                       # never :latest
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../application" && pwd)"

run() { echo "+ $*"; "$@"; }

for component in backend:notes-api frontend:notes-web; do
  dir="${component%%:*}"
  image="${component##*:}"

  echo ""
  echo "=== Building ${image}:${TAG} ==="
  run docker build -t "${image}:${TAG}" "${APP_DIR}/${dir}"

  echo "=== Loading ${image}:${TAG} into kind cluster '${CLUSTER}' ==="
  run kind load docker-image "${image}:${TAG}" --name "${CLUSTER}"
done

echo ""
echo "=== Pre-pulling postgres so the first deploy isn't waiting on a download ==="
# Optional but kind: without it the database pod sits in ContainerCreating for
# a minute on a slow connection and looks broken.
run docker pull postgres:17.5-alpine
run kind load docker-image postgres:17.5-alpine --name "${CLUSTER}"

echo ""
echo "Images are now in the cluster. The manifests reference them as:"
echo "  image: notes-api:${TAG}   imagePullPolicy: IfNotPresent"
echo "(IfNotPresent matters — with Always the kubelet ignores the loaded copy.)"
