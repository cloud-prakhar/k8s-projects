#!/usr/bin/env bash
# Builds this project's container images and loads them into the Kind cluster.
#
# WHY this exists: a Kind "node" is a Docker container with its own image store.
# An image sitting in your laptop's Docker daemon is invisible to it, which is
# why a locally built image gives ErrImagePull/ImagePullBackOff until it is
# loaded. `kind load docker-image` copies it into every node.
set -euo pipefail

CLUSTER="${CLUSTER:-kubernetes-lab}"
TAG="${TAG:-1.0.0}"                # never :latest — see docs/CONVENTIONS.md §5
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../application" && pwd)"

run() { echo "+ $*"; "$@"; }

# component-directory : image-name
COMPONENTS=(
  "frontend:<project>-frontend"
  "backend:<project>-backend"
)

for entry in "${COMPONENTS[@]}"; do
  dir="${entry%%:*}"
  image="${entry##*:}"
  [[ -f "$APP_DIR/$dir/Dockerfile" ]] || { echo "-- skip $dir (no Dockerfile)"; continue; }

  echo ""
  echo "=== Building $image:$TAG ==="
  run docker build -t "$image:$TAG" "$APP_DIR/$dir"

  echo "=== Loading $image:$TAG into kind cluster '$CLUSTER' ==="
  run kind load docker-image "$image:$TAG" --name "$CLUSTER"
done

echo ""
echo "Images available in the cluster. Manifests must use:"
echo "  image: <name>:$TAG"
echo "  imagePullPolicy: IfNotPresent   # otherwise the kubelet tries to pull from a registry"
