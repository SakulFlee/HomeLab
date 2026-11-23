#!/usr/bin/env bash
# Remove old Forgejo runner cache files and old job workspaces.
#
# The runner's registration, config and current job are never touched. The
# cleanup is skipped entirely while a FORGEJO-ACTIONS job container is running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd docker

runner_root="${RUNNER_DATA_DIR:-${LIVE_DATA_DIR}/forgejo-runner}"
cache_dir="${runner_root}/cache"
workspace_dir="${runner_root}/workspace"
cache_days="${RUNNER_CACHE_DAYS:-14}"
workspace_days="${RUNNER_WORKSPACE_DAYS:-7}"
[[ "${cache_days}" =~ ^[0-9]+$ ]] || die "RUNNER_CACHE_DAYS must be a whole number"
[[ "${workspace_days}" =~ ^[0-9]+$ ]] || die "RUNNER_WORKSPACE_DAYS must be a whole number"

if [[ ! -d "${runner_root}" ]]; then
  log "runner data directory ${runner_root} does not exist; nothing to do"
  exit 0
fi

if docker ps --format '{{.Names}}' | grep -q '^FORGEJO-ACTIONS'; then
  log "a Forgejo Actions job is running; skipping runner cache cleanup"
  exit 0
fi

log "runner cleanup before: $(du -sh "${runner_root}" 2>/dev/null | awk '{print $1}')"

if [[ -d "${cache_dir}" ]]; then
  log "removing cache files older than ${cache_days} days"
  find "${cache_dir}" -type f -mtime +"${cache_days}" -print -delete
  find "${cache_dir}" -depth -type d -empty -delete 2>/dev/null || true
else
  log "no cache directory at ${cache_dir}"
fi

if [[ -d "${workspace_dir}" ]]; then
  log "removing job workspaces older than ${workspace_days} days"
  find "${workspace_dir}" -mindepth 1 -maxdepth 1 -type d \
    -mtime +"${workspace_days}" -print -exec rm -rf -- {} +
else
  log "no workspace directory at ${workspace_dir}"
fi

log "runner cleanup after: $(du -sh "${runner_root}" 2>/dev/null | awk '{print $1}')"
