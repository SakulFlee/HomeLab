#!/usr/bin/env bash
# Regenerate the single-file compose.yaml from the vendored upstream files.
# Compose `include` conflicts with Dockge's parser and loses the proxy overlay
# environment, so the top-level file is a merged, unresolved template.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

docker compose \
  --env-file vendor/.env.example \
  -f vendor/docker-compose.yml \
  -f vendor/docker-compose.proxy.yml \
  -f compose.override.yaml \
  config --no-interpolate --no-path-resolution --no-normalize \
  > compose.yaml.tmp
mv -f compose.yaml.tmp compose.yaml
