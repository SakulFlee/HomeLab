#!/bin/bash
set -euo pipefail

session="hytale"

if [[ ! -s /data/Server/HytaleServer.jar ]]; then
  echo "missing /data/Server/HytaleServer.jar" >&2
  exit 1
fi
if [[ ! -s /data/Assets.zip ]]; then
  echo "missing /data/Assets.zip" >&2
  exit 1
fi
if [[ ! -s /etc/machine-id ]]; then
  echo "missing /etc/machine-id; bind-mount the pinned machine id" >&2
  exit 1
fi

tmux kill-session -t "${session}" 2>/dev/null || true

aot=""
if [[ -f /data/Server/HytaleServer.aot ]]; then
  aot="-XX:AOTCache=HytaleServer.aot"
fi

# shellcheck disable=SC2086
tmux new-session -d -s "${session}" -c /data/Server -x 300 -y 60 \
  "java -Xms512M -Xmx4G -XX:+UseG1GC -XX:+UseStringDeduplication ${aot} \
    -jar HytaleServer.jar \
    --assets ../Assets.zip \
    --accept-early-plugins \
    --backup \
    --backup-dir backups \
    --backup-frequency 525600 \
    --backup-max-count 100000 \
    --backup-archive-max-count 100000"

shutdown() {
  # Hytale needs SIGTERM for its own graceful flush. tmux is only the console;
  # do not just kill the session, or the JVM gets SIGHUP instead.
  pkill -TERM -f HytaleServer.jar 2>/dev/null || true
  for _ in $(seq 1 48); do
    pgrep -f HytaleServer.jar >/dev/null 2>&1 || break
    sleep 5 &
    wait $! || true
  done
  tmux kill-session -t "${session}" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

while tmux has-session -t "${session}" 2>/dev/null; do
  sleep 5 &
  wait $! || true
done

# Reaching here means the JVM exited on its own. Exit non-zero so Docker's
# restart policy brings it back.
exit 1
