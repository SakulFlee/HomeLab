#!/usr/bin/env bash
# Small restic helper. The full runbook is in docs/restore.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd restic

export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-${BACKUP_DIR}/restic}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-${RUNTIME_SECRETS_DIR}/restic-password}"
[[ -r "${RESTIC_PASSWORD_FILE}" ]] || die "missing restic password file"

case "${1:-}" in
  snapshots)
    restic snapshots
    ;;
  ls)
    shift
    restic ls "$@"
    ;;
  restore)
    target="${2:-/srv/restore}"
    install -d -m 0755 "${target}"
    restic restore latest --target "${target}"
    log "restored latest snapshot into ${target}"
    ;;
  *)
    cat >&2 <<'EOF'
usage: restore.sh <command>

  snapshots                 list snapshots
  ls <snapshot> [path]      list files in a snapshot
  restore [target]          restore the latest snapshot to target
                            (default: /srv/restore)

Service-specific restore steps are in docs/restore.md.
EOF
    exit 2
    ;;
esac
