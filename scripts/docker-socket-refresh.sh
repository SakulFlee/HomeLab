#!/usr/bin/env bash
# Restart containers whose bind-mounted Docker socket points at an old inode.
#
# dockerd recreates /run/docker.sock on every restart (package upgrade,
# `systemctl restart docker`). A socket bind mount is tied to the inode that
# existed when the container was created, so containers that survived the
# restart keep talking to the orphaned socket and fail with
# "Cannot connect to the Docker daemon at unix:///var/run/docker.sock".
# `live-restore: true` in daemon.json is what keeps them alive across the
# restart instead of restarting them onto the new socket.
#
# deploy.sh calls this on every run, and the docker.service drop-in installed
# by bootstrap.sh calls it again right after the daemon starts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd docker
require_cmd jq

socket=/run/docker.sock
if [[ ! -S ${socket} ]]; then
  log "no docker socket at ${socket}; nothing to refresh"
  exit 0
fi
host_inode="$(stat -c %i "${socket}")"

while read -r name; do
  [[ -n ${name} ]] || continue
  mapfile -t destinations < <(
    docker inspect --format '{{json .Mounts}}' "${name}" 2>/dev/null \
      | jq -r '.[] | select(.Source == "/var/run/docker.sock" or .Source == "/run/docker.sock") | .Destination' \
      || true
  )
  for dest in "${destinations[@]}"; do
    # Docker reports exec failures (e.g. a missing `stat`) on stdout, so
    # validate the shape instead of trusting the exit status.
    inode="$(docker exec "${name}" stat -c %i "${dest}" 2>/dev/null || true)"
    if [[ ! ${inode} =~ ^[0-9]+$ ]]; then
      log "WARN: cannot read the inode of ${dest} inside ${name}; leaving it alone"
      continue
    fi
    if [[ ${inode} != "${host_inode}" ]]; then
      log "restarting ${name}: ${dest} has stale socket inode ${inode} (live: ${host_inode})"
      docker restart "${name}" >/dev/null
    fi
  done
done < <(docker ps --format '{{.Names}}')
