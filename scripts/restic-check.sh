#!/usr/bin/env bash
# Verify the local restic repository. The timer runs this weekly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd restic

export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-${BACKUP_DIR}/restic}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-${RUNTIME_SECRETS_DIR}/restic-password}"

[[ -r "${RESTIC_PASSWORD_FILE}" ]] || die "missing restic password file"

subset="${RESTIC_CHECK_SUBSET:-10%}"
log "checking ${RESTIC_REPOSITORY} with read-data-subset=${subset}"
restic check --read-data-subset="${subset}"
notify "Backup verification passed" "restic check completed with subset ${subset}" default
