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
# OpenChamber shares the OpenCode workspace and runs as the same UID, so its
# chats for project-less conversations have to be writable there. It also
# hands the path to the OpenCode server as a location, which is why the
# default (/data/chats, inside OpenChamber's own container) fails with
# LocationNotFoundError.
install -d -m 0755 -o 990 -g 990 "${LIVE_DATA_DIR}/opencode/workspace/.openchamber"
install -d -m 0755 -o 990 -g 990 "${LIVE_DATA_DIR}/opencode/workspace/.openchamber/chats"
# OpenChamber shares the OpenCode workspace and runs as the same UID (990),
# so its data directory must belong to that user too. Reclaim files written by
# the image's default UID (1000) once, when switching.
install -d -m 0755 -o 990 -g 990 "${LIVE_DATA_DIR}/openchamber"
if [[ -n "$(find "${LIVE_DATA_DIR}/openchamber" ! -user 990 -print -quit 2>/dev/null)" ]]; then
  chown -R 990:990 "${LIVE_DATA_DIR}/openchamber"
fi
# Hermes Agent is no longer deployed; its data directory is left on the host for
# the operator to remove by hand.
install -d -m 0700 -o 1000 -g 1000 "${LIVE_DATA_DIR}/syncthing/config"
install -d -m 0755 -o 1000 -g 1000 "${LIVE_DATA_DIR}/syncthing/data"

# Fluxer: postgres is 70; the rest are managed by their images.
install -d -m 0700 -o 70 -g 70 "${LIVE_DATA_DIR}/fluxer/postgres-data"
for dir in seaweedfs-data meilisearch-data nats-data valkey-data edge-data edge-config; do
  install -d -m 0755 "${LIVE_DATA_DIR}/fluxer/${dir}"
done

# Paperless: the image's paperless user is 1000, PostgreSQL 18-alpine is 70 and
# Valkey's official image is 999. The media tree is the one that matters: it is
# the documents, and a restore copies it back as 1000:1000.
install -d -m 0755 -o 1000 -g 1000 "${LIVE_DATA_DIR}/paperless/data"
install -d -m 0755 -o 1000 -g 1000 "${LIVE_DATA_DIR}/paperless/media"
install -d -m 0755 -o 1000 -g 1000 "${LIVE_DATA_DIR}/paperless/consume"
install -d -m 0755 -o 1000 -g 1000 "${LIVE_DATA_DIR}/paperless/export"
install -d -m 0700 -o 70 -g 70 "${LIVE_DATA_DIR}/paperless/postgres"
install -d -m 0750 -o 999 -g 999 "${LIVE_DATA_DIR}/paperless/valkey"

# Root-owned state (container runtimes, certificates, UI state). Ollama's
# models live here too; they run as root in the official image and are
# excluded from restic because they can be pulled again.
for dir in caddy dockge wg-easy forgejo-runner cloudflare-ddns ntfy homeassistant ollama; do
  install -d -m 0755 "${LIVE_DATA_DIR}/${dir}"
done
# Renovate's image runs as uid 12021 with gid 0, so hardcoding the image uid
# would break on an image bump. Group root plus g+w lets it write.
install -d -m 2770 -o 1000 -g 0 "${LIVE_DATA_DIR}/renovate"

log "data directories prepared under ${LIVE_DATA_DIR}"
