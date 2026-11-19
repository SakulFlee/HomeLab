#!/usr/bin/env bash
# Weekly verification of the pulled repository. Reads a sample of pack data,
# so bitrot in the copy is detected before a restore needs it.
set -euo pipefail

# shellcheck source=homelab-restic-common.sh
. "${HOME}/.local/bin/homelab-restic-common.sh"

lock_repo
require_repo

restic --no-lock \
  -r "${REPO}" --password-file "${REPO_PASSWORD}" \
  check --read-data-subset="${RESTIC_CHECK_SUBSET:-10%}"
