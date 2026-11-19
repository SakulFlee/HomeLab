#!/usr/bin/env bash
# Pull the HomeLab restic repository to this machine. The homelab exposes the
# repository read-only over a restricted sftp key, so --no-lock is required
# (restic would otherwise try to write a lock into the source).
set -euo pipefail

# shellcheck source=homelab-restic-common.sh
. "${HOME}/.local/bin/homelab-restic-common.sh"

if [[ -r "${HOME}/.config/homelab/notify.env" ]]; then
  set -a
  . "${HOME}/.config/homelab/notify.env"
  set +a
fi

lock_repo
require_repo

RESTIC_OPTS=(--no-lock -r "${REPO}" --password-file "${REPO_PASSWORD}")

before="$(restic "${RESTIC_OPTS[@]}" snapshots --json 2>/dev/null | jq 'length')"

restic "${RESTIC_OPTS[@]}" copy \
  --from-repo "${SOURCE_REPO}" \
  --from-password-file "${SOURCE_PASSWORD}"

after="$(restic "${RESTIC_OPTS[@]}" snapshots --json 2>/dev/null | jq 'length')"

# Dead-man's-switch: ping only when a new snapshot actually arrived, so a
# failing homelab backup or a stale connection shows up as a missing ping.
if (( ${after:-0} > ${before:-0} )) && [[ -n "${HEALTHCHECKS_PULL_URL:-}" ]]; then
  curl -fsS -m 10 "${HEALTHCHECKS_PULL_URL%/}" >/dev/null 2>&1 || true
  echo "pinged healthchecks (snapshots ${before} -> ${after})"
fi
