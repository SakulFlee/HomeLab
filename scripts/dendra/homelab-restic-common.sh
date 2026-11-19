#!/usr/bin/env bash
# Shared settings for the HomeLab restic mirror on this machine (Dendra).
#
# Sourced by homelab-restic-{pull,prune,check}.sh, so the repository location
# is one line instead of three. The previous layout had the path copied into
# every script and it drifted; do not reintroduce that.

MOUNT_POINT=/mnt/btrfs-raid1
REPO="${MOUNT_POINT}/backups/homelab/restic"
REPO_PASSWORD="${HOME}/.config/restic/dendra-password"

SOURCE_REPO="sftp:homelab:/srv/backup/restic"
SOURCE_PASSWORD="${HOME}/.config/restic/homelab-password"

LOCK_FILE="${HOME}/.cache/homelab-restic-pull.lock"

# /mnt/btrfs-raid1 is an x-systemd.automount with a 5 minute idle timeout, so
# the -d test both triggers the mount and reveals whether it worked. Comparing
# the resolved mount target (not the fs type) matters because / is btrfs too: a
# stale directory created on the root filesystem would otherwise pass an
# fstype check, and restic would happily write the mirror to the wrong disk.
require_repo() {
  local target
  if [[ ! -d "${REPO}" ]]; then
    echo "restic repository is missing: ${REPO}" >&2
    exit 1
  fi
  # An automount reports two entries (autofs, then the real mount), hence tail.
  target="$(findmnt -T "${REPO}" -no TARGET 2>/dev/null | tail -n1)"
  if [[ "${target}" != "${MOUNT_POINT}" ]]; then
    echo "restic repository is not on ${MOUNT_POINT} (resolved mount: ${target:-none}): ${REPO}" >&2
    exit 1
  fi
}

# One lock for pull, prune and check: restic must never have two writers on the
# same repository.
lock_repo() {
  install -d -m 0755 "${HOME}/.cache"
  exec 9>"${LOCK_FILE}"
  flock -n 9 || { echo "another pull, prune or check is already running"; exit 0; }
}
