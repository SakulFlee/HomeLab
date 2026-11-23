#!/usr/bin/env bash
# Prepare a directory under /srv/docker to become a nested btrfs subvolume.
#
# The copy uses reflinks, so the data blocks are shared with the original and
# the operation does not need free space equal to the directory size. It does
# not delete or replace the original: stop the service, run this, verify the
# output, then remove the original and rename the prepared subvolume.
#
# Nested subvolumes are excluded from `btrfs subvolume snapshot /srv/docker`,
# which is what keeps deploy rollback snapshots small.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd btrfs
require_cmd cp
require_cmd find
require_cmd du

usage() {
  cat <<'EOF'
Usage: promote-subvolume.sh /srv/docker/<path>

Prepares /srv/docker/<path> as a nested btrfs subvolume under
/srv/docker/<path>.new. Stop the service first. The original is left intact.

After verifying the output:

  sudo rm -rf /srv/docker/<path>
  sudo mv /srv/docker/<path>.new /srv/docker/<path>
  sudo docker compose -f /opt/homelab/stacks/<stack>/compose.yaml \
    up -d --force-recreate
EOF
}

target="${1:-}"
if [[ -z "${target}" || "${target}" == "-h" || "${target}" == "--help" ]]; then
  usage
  exit 0
fi
target="${target%/}"
tmp="${target}.new"

case "${target}" in
  /srv/docker/*) ;;
  *) die "target must be a path under /srv/docker" ;;
esac
[[ -d "${target}" ]] || die "${target} is not a directory"
if btrfs subvolume show "${target}" >/dev/null 2>&1; then
  die "${target} is already a btrfs subvolume"
fi
[[ ! -e "${tmp}" ]] || die "${tmp} already exists; inspect/remove it first"

btrfs subvolume create "${tmp}" >/dev/null
log "created ${tmp}; copying with reflinks"

if ! cp -a --reflink=always "${target}/." "${tmp}/"; then
  log "ERROR: reflink copy failed; ${tmp} is incomplete. The original is untouched."
  log "Remove ${tmp} with: btrfs subvolume delete ${tmp}"
  exit 1
fi

chown --reference="${target}" "${tmp}"
chmod --reference="${target}" "${tmp}"

src_bytes="$(du -sb "${target}" | awk '{print $1}')"
dst_bytes="$(du -sb "${tmp}" | awk '{print $1}')"
src_entries="$(find "${target}" -mindepth 1 | wc -l)"
dst_entries="$(find "${tmp}" -mindepth 1 | wc -l)"

log "source: ${src_bytes} bytes, ${src_entries} entries"
log "copy:   ${dst_bytes} bytes, ${dst_entries} entries"
if [[ "${src_bytes}" != "${dst_bytes}" || "${src_entries}" != "${dst_entries}" ]]; then
  die "copy verification failed; ${tmp} is incomplete and the original is untouched"
fi

log "verified ${tmp}"
log "the service must be stopped while you finalize:"
log "  sudo rm -rf ${target}"
log "  sudo mv ${tmp} ${target}"
log "  btrfs subvolume show ${target}"
log "then recreate the stack with --force-recreate so the bind mount is remounted"
