#!/usr/bin/env bash
# Run Fluxer with the upstream files, the proxy overlay and the homelab
# override. Compose `include` does not merge the proxy overlay environment
# reliably, so this uses explicit -f files and a fixed project directory.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

exec docker compose \
  --project-directory "$PWD" \
  --env-file "${FLUXER_ENV_FILE:-/run/homelab/secrets/fluxer.env}" \
  -f vendor/docker-compose.yml \
  -f vendor/docker-compose.proxy.yml \
  -f compose.override.yaml \
  "$@"
