#!/usr/bin/env bash
# Create the bind-mount directories with the UIDs the images expect.
# Safe to re-run; it only creates missing directories and does not recurse.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root

install -d -m 0755 "${LIVE_DATA_DIR}"

# Forgejo: image runs as UID/GID 1000.
install -d -m 0750 -o 1000 -g 1000 "${LIVE_DATA_DIR}/forgejo/data"
install -d -m 0750 -o 1000 -g 1000 "${LIVE_DATA_DIR}/forgejo/custom"
install -d -m 0750 -o 1000 -g 1000 "${LIVE_DATA_DIR}/forgejo/archive"
# Kept outside /data/ssh because the image resets that directory's ownership
# at startup. Forgejo's built-in SSH server runs as UID 1000 and reads these.
install -d -m 0700 -o 1000 -g 1000 "${LIVE_DATA_DIR}/forgejo/ssh-keys"
# postgres:18-alpine runs as UID/GID 70. PostgreSQL 18+ mounts the parent
# directory; the image creates the major-version subdirectory itself.
install -d -m 0700 -o 70 -g 70 "${LIVE_DATA_DIR}/forgejo/postgres"

# Minecraft UID 988, Hytale UID 989, OpenCode UID 990, Syncthing UID 1000.
install -d -m 0755 -o 988 -g 988 "${LIVE_DATA_DIR}/minecraft"
install -d -m 0755 -o 989 -g 989 "${LIVE_DATA_DIR}/hytale/data"
install -d -m 0700 -o 989 -g 989 "${LIVE_DATA_DIR}/hytale/secrets"

# Hytale's auth.enc is encrypted with a key derived from /etc/machine-id. The
# file must exist before Docker starts, or Docker creates a directory at the
# bind-mount path and the container cannot start. During a real migration,
# overwrite this with the old /var/lib/hytale/.machine-id.
hytale_mid="${LIVE_DATA_DIR}/hytale/machine-id"
if [[ -d "${hytale_mid}" ]]; then
  rmdir "${hytale_mid}" 2>/dev/null \
    || die "${hytale_mid} is a non-empty directory; remove it before continuing"
fi
if [[ ! -f "${hytale_mid}" ]]; then
  tr -d '-' < /proc/sys/kernel/random/uuid > "${hytale_mid}"
  chmod 0444 "${hytale_mid}"
fi
install -d -m 0700 -o 990 -g 990 "${LIVE_DATA_DIR}/opencode/home"
install -d -m 0755 -o 990 -g 990 "${LIVE_DATA_DIR}/opencode/workspace"
install -d -m 0700 -o 1000 -g 1000 "${LIVE_DATA_DIR}/syncthing/config"
install -d -m 0755 -o 1000 -g 1000 "${LIVE_DATA_DIR}/syncthing/data"

# Fluxer: postgres is 70; the rest are managed by their images.
install -d -m 0700 -o 70 -g 70 "${LIVE_DATA_DIR}/fluxer/postgres-data"
for dir in seaweedfs-data meilisearch-data nats-data valkey-data edge-data edge-config; do
  install -d -m 0755 "${LIVE_DATA_DIR}/fluxer/${dir}"
done

# Root-owned state (container runtimes, certificates, UI state).
for dir in caddy dockge wg-easy forgejo-runner cloudflare-ddns; do
  install -d -m 0755 "${LIVE_DATA_DIR}/${dir}"
done
install -d -m 0755 -o 1000 -g 1000 "${LIVE_DATA_DIR}/renovate"

log "data directories prepared under ${LIVE_DATA_DIR}"
