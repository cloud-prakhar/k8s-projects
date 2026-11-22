#!/usr/bin/env bash
# Builds and pushes Project 05's images:
#
#   webapp-1.0.0   the application
#   webapp-2.0.0   the SAME code with APP_VERSION=2.0.0 baked in — a genuinely
#                  different image, so stage 11's rollouts, canary and
#                  blue/green change what is running, not just an env var
#   loadgen-1.0.0  the load generator every lesson measures with
#
# WHY a registry: EKS nodes are EC2 instances that can only run images they can
# PULL. There is no `kind load` on a managed cluster.
#
# Every step here is explained in ./manual-steps.md Part 2.
set -euo pipefail

IMAGE_REPO="${IMAGE_REPO:-cloudprakhargupta/web-platform}"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../application" && pwd)"

run() { echo "+ $*"; "$@"; }

echo "Publishing to ${IMAGE_REPO}  (authenticate first: docker login)"

for v in 1.0.0 2.0.0; do
  image="${IMAGE_REPO}:webapp-${v}"
  echo ""; echo "=== Building ${image} ==="
  # --build-arg bakes the version into the image (see application/webapp/Dockerfile).
  run docker build --build-arg "APP_VERSION=${v}" -t "${image}" "${APP_DIR}/webapp"
  run docker push "${image}"
done

image="${IMAGE_REPO}:loadgen-1.0.0"
echo ""; echo "=== Building ${image} ==="
run docker build -t "${image}" "${APP_DIR}/loadgen"
run docker push "${image}"

echo ""; echo "=== Verifying the registry really has them ==="
for t in webapp-1.0.0 webapp-2.0.0 loadgen-1.0.0; do
  run docker manifest inspect "${IMAGE_REPO}:${t}" >/dev/null
  echo "  ✅ ${IMAGE_REPO}:${t}"
done

cat <<MSG

Images published. Pushed under a different IMAGE_REPO? Change ONLY the images:
field in manifests/19-final/kustomization.yaml — never the manifests.
MSG
