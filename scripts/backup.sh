#!/usr/bin/env bash
# Application-consistent backup into the local restic repository.
#
# Forgejo and Minecraft are stopped for the duration so their data is
# quiescent. Fluxer gets a PostgreSQL dump while the stack stays up; Hytale is
# asked for its own archive through the tmux console.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd docker
require_cmd restic
require_cmd jq
require_cmd btrfs

export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-${BACKUP_DIR}/restic}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-${RUNTIME_SECRETS_DIR}/restic-password}"

[[ -r "${RESTIC_PASSWORD_FILE}" ]] || die "missing restic password file: ${RESTIC_PASSWORD_FILE}"
[[ -d "${LIVE_DATA_DIR}" ]] || die "missing live data directory: ${LIVE_DATA_DIR}"

install -d -m 0755 "${BACKUP_DIR}/dumps"
install -d -m 0755 "${BACKUP_DIR}/repo-snapshots"

stamp="$(date +%Y%m%dT%H%M%S)"
dump_dir="${BACKUP_DIR}/dumps"

if ! restic cat config >/dev/null 2>&1; then
  log "initializing restic repository ${RESTIC_REPOSITORY}"
  restic init
fi

forgejo_stopped=0
minecraft_stopped=0

start_services() {
  if ((minecraft_stopped)); then
    compose minecraft start || true
  fi
  if ((forgejo_stopped)); then
    compose forgejo start forgejo || true
  fi
}
trap start_services EXIT

if stack_exists forgejo; then
  log "stopping forgejo for a consistent dump"
  compose forgejo stop forgejo >/dev/null 2>&1 || true
  forgejo_stopped=1
  forgejo_pw="$(cat "${RUNTIME_SECRETS_DIR}/forgejo/forgejo_db_password")"
  if ! compose forgejo exec -T -e "PGPASSWORD=${forgejo_pw}" db \
      pg_dump -Fc -U forgejo -d forgejo > "${dump_dir}/forgejo-${stamp}.dump"; then
    die "forgejo pg_dump failed"
  fi
  log "wrote ${dump_dir}/forgejo-${stamp}.dump"
fi

if stack_exists fluxer; then
  if docker inspect -f '{{.State.Running}}' fluxer-postgres >/dev/null 2>&1; then
    log "dumping fluxer postgres"
    if ! docker exec fluxer-postgres sh -c \
        'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -Fc -U fluxer -d fluxer' \
        > "${dump_dir}/fluxer-${stamp}.dump"; then
      die "fluxer pg_dump failed"
    fi
    log "wrote ${dump_dir}/fluxer-${stamp}.dump"
  else
    log "WARN: fluxer-postgres is not running; skipping its dump"
  fi
fi

if stack_exists minecraft; then
  log "stopping minecraft for a quiescent world"
  compose minecraft stop >/dev/null 2>&1 || true
  minecraft_stopped=1
fi

if stack_exists hytale && [[ "$(docker inspect -f '{{.State.Running}}' hytale 2>/dev/null || true)" == "true" ]]; then
  log "asking hytale for an archive"
  hytale_backups="${LIVE_DATA_DIR}/hytale/data/Server/backups"
  install -d -m 0755 "${hytale_backups}"
  docker exec hytale tmux send-keys -t hytale '/backup' Enter >/dev/null 2>&1 || true
  deadline=$((SECONDS + 300))
  while ((SECONDS < deadline)); do
    if find "${hytale_backups}" -maxdepth 1 -type f -name '*.zip' -newermt '-10 minutes' -print -quit | grep -q .; then
      break
    fi
    sleep 10 &
    wait $! || true
  done
  find "${hytale_backups}" -maxdepth 1 -type f -name '*.zip' -mtime +7 -print -delete || true
fi

log "backing up ${LIVE_DATA_DIR} and ${dump_dir}"
restic backup \
  --tag homelab \
  --exclude="${LIVE_DATA_DIR}/forgejo/archive" \
  --exclude="${LIVE_DATA_DIR}/forgejo/postgres" \
  --exclude="${LIVE_DATA_DIR}/fluxer/postgres-data" \
  --exclude="${LIVE_DATA_DIR}/fluxer/meilisearch-data" \
  --exclude="${LIVE_DATA_DIR}/fluxer/nats-data" \
  --exclude="${LIVE_DATA_DIR}/fluxer/valkey-data" \
  --exclude="${LIVE_DATA_DIR}/minecraft/backups" \
  --exclude="${LIVE_DATA_DIR}/hytale/data/Server/logs" \
  --exclude="${LIVE_DATA_DIR}/forgejo-runner" \
  --exclude="${LIVE_DATA_DIR}/renovate" \
  --exclude="${LIVE_DATA_DIR}/syncthing/data" \
  "${LIVE_DATA_DIR}" "${dump_dir}"

find "${dump_dir}" -maxdepth 1 -type f -mtime +14 -print -delete || true

# Keep a rollback point of the repository itself before prune. This is what
# protects against a restic/prune mistake, not against disk loss.
if btrfs subvolume show "${BACKUP_DIR}/restic" >/dev/null 2>&1; then
  repo_snap="${BACKUP_DIR}/repo-snapshots/restic-${stamp}"
  btrfs subvolume snapshot -r "${BACKUP_DIR}/restic" "${repo_snap}"
  log "created restic repository snapshot ${repo_snap}"
  find "${BACKUP_DIR}/repo-snapshots" -mindepth 1 -maxdepth 1 -type d \
    -name 'restic-*' -mtime +14 -print0 \
    | xargs -0 -r -n1 btrfs subvolume delete >/dev/null || true
else
  log "WARN: ${BACKUP_DIR}/restic is not a btrfs subvolume; skipping repo snapshot"
fi

log "pruning old snapshots"
restic forget \
  --keep-daily 14 \
  --keep-weekly 8 \
  --keep-monthly 12 \
  --prune

notify "Backup complete" "restic backup finished at $(date -Is)" default
