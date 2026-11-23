#!/usr/bin/env bash
# Prune unused Docker images and old build cache.
#
# Volumes and running/stopped containers are never touched: `image prune -a`
# only removes images that no container references, and `builder prune` only
# removes build cache. The `until` filters keep recent images/cache available
# for a rollback or a quick rebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd docker

image_days="${DOCKER_IMAGE_PRUNE_DAYS:-14}"
cache_days="${DOCKER_BUILD_CACHE_PRUNE_DAYS:-7}"
[[ "${image_days}" =~ ^[0-9]+$ ]] || die "DOCKER_IMAGE_PRUNE_DAYS must be a whole number"
[[ "${cache_days}" =~ ^[0-9]+$ ]] || die "DOCKER_BUILD_CACHE_PRUNE_DAYS must be a whole number"

image_hours=$((image_days * 24))
cache_hours=$((cache_days * 24))

log "Docker usage before cleanup:"
docker system df || true

rc=0
if (( image_hours > 0 )); then
  log "pruning unused images older than ${image_days} days"
  docker image prune -a -f --filter "until=${image_hours}h" \
    || { log "WARN: image prune failed"; rc=1; }
fi
if (( cache_hours > 0 )); then
  log "pruning build cache older than ${cache_days} days"
  docker builder prune -f --filter "until=${cache_hours}h" \
    || { log "WARN: builder prune failed"; rc=1; }
fi

log "Docker usage after cleanup:"
docker system df || true
exit "${rc}"
