#!/usr/bin/env bash
# Apply the retention policy to the pulled repository. restic copy never
# deletes on the destination, so without this the off-box repo grows forever.
set -euo pipefail

# shellcheck source=homelab-restic-common.sh
. "${HOME}/.local/bin/homelab-restic-common.sh"

lock_repo
require_repo

restic \
  -r "${REPO}" --password-file "${REPO_PASSWORD}" \
  forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
