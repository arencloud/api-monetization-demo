#!/usr/bin/env bash

set -Eeuo pipefail

plugin_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_root=$(cd "$plugin_root/../.." && pwd)
builder_image="docker.io/library/node:22.22.0-bookworm-slim@sha256:dd9d21971ec4395903fa6143c2b9267d048ae01ca6d3ea96f16cb30df6187d94"

if command -v podman >/dev/null 2>&1; then
  runtime=(podman run --rm --userns=keep-id -v "$repo_root:/workspace:Z")
elif command -v docker >/dev/null 2>&1; then
  runtime=(docker run --rm -v "$repo_root:/workspace")
else
  echo "error: podman or docker is required to reproduce the RHDH plugin" >&2
  exit 1
fi

"${runtime[@]}" \
  --env NPM_CONFIG_CACHE=/tmp/npm-cache \
  --workdir /workspace/plugins/rhdh-policy-catalog \
  "$builder_image" \
  sh -eu -c '
    npm ci --ignore-scripts
    npm run tsc
    CI=true npm test -- --runInBand
    npm run export-dynamic -- --clean
    npm run package:dynamic
  '
