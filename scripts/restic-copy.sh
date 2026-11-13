#!/usr/bin/env bash
# Copy the local restic repository to Dendra when Dendra is reachable.
# This is a repository-aware copy, not a file sync.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd restic
require_cmd ssh

export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-${BACKUP_DIR}/restic}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-${RUNTIME_SECRETS_DIR}/restic-password}"

DENDRA_HOST="${DENDRA_HOST:-dendra}"
DENDRA_REPO="${DENDRA_REPO:-sftp:${DENDRA_HOST}:/srv/restic/homelab}"
DENDRA_PASSWORD_FILE="${DENDRA_PASSWORD_FILE:-${RUNTIME_SECRETS_DIR}/restic-dendra-password}"
STALE_SECONDS="${STALE_SECONDS:-259200}" # 72h
LAST_COPY_FILE="${STATE_DIR}/restic-copy.last"

[[ -r "${RESTIC_PASSWORD_FILE}" ]] || die "missing restic password file"
[[ -r "${DENDRA_PASSWORD_FILE}" ]] || die "missing Dendra restic password file"
install -d -m 0755 "${STATE_DIR}"

exec 9>/run/lock/homelab-restic-copy.lock
if ! flock -n 9; then
  log "another restic copy is already running; skipping"
  exit 0
fi

stale_check() {
  if [[ -r "${LAST_COPY_FILE}" ]]; then
    local last now
    last="$(cat "${LAST_COPY_FILE}")"
    now="$(date +%s)"
    if ((now - last > STALE_SECONDS)); then
      notify "Backup copy is stale" "Last successful restic copy to ${DENDRA_HOST} was $(date -d "@${last}" -Is)" critical
    fi
  else
    notify "Backup copy has never run" "No successful restic copy to ${DENDRA_HOST} yet" high
  fi
}

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${DENDRA_HOST}" true >/dev/null 2>&1; then
  log "${DENDRA_HOST} is not reachable; leaving the local copy in place"
  stale_check
  exit 0
fi

source_repo="${RESTIC_REPOSITORY}"
latest_snapshot="$(find "${BACKUP_DIR}/repo-snapshots" -mindepth 1 -maxdepth 1 -type d \
  -name 'restic-*' -printf '%p\n' 2>/dev/null | sort | tail -n 1 || true)"
if [[ -n "${latest_snapshot}" ]]; then
  source_repo="${latest_snapshot}"
  log "copying from repository snapshot ${source_repo}"
fi

if ! restic -r "${DENDRA_REPO}" --password-file "${DENDRA_PASSWORD_FILE}" cat config >/dev/null 2>&1; then
  log "initializing Dendra restic repository ${DENDRA_REPO}"
  restic -r "${DENDRA_REPO}" --password-file "${DENDRA_PASSWORD_FILE}" init
fi

log "copying ${source_repo} -> ${DENDRA_REPO}"
if restic copy --help 2>&1 | grep -q -- '--from-repo'; then
  # restic 0.19+: destination is --repo, source is --from-repo.
  restic -r "${DENDRA_REPO}" --password-file "${DENDRA_PASSWORD_FILE}" \
    copy --from-repo "${source_repo}" \
         --from-password-file "${RESTIC_PASSWORD_FILE}"
else
  # Older restic: source is -r, destination is --repo2.
  restic -r "${source_repo}" --password-file "${RESTIC_PASSWORD_FILE}" \
    copy --repo2 "${DENDRA_REPO}" --password-file2 "${DENDRA_PASSWORD_FILE}"
fi

date +%s > "${LAST_COPY_FILE}"
notify "Backup copied" "restic copy to ${DENDRA_HOST} completed" default
