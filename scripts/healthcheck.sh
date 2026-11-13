#!/usr/bin/env bash
# Minimal post-deploy checks. Extend as services are added.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd docker
require_cmd curl

fail=0

pass() { log "ok: $*"; }
bad() { log "FAIL: $*"; fail=1; }

running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

http_ok() {
  curl -fsS --max-time 5 "$1" >/dev/null 2>&1
}

tcp_ok() {
  timeout 5 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$1" >/dev/null 2>&1
}

if stack_exists forgejo; then
  running forgejo && pass "forgejo container" || bad "forgejo container"
  running forgejo-db && pass "forgejo-db container" || bad "forgejo-db container"
  http_ok "http://127.0.0.1:3000/api/v1/version" \
    && pass "forgejo HTTP" || bad "forgejo HTTP"
fi

if stack_exists fluxer; then
  if docker ps --format '{{.Names}}' | grep -q '^fluxer-edge$'; then
    pass "fluxer edge container"
  else
    bad "fluxer edge container"
  fi
  http_ok "http://127.0.0.1:8080/" \
    && pass "fluxer edge HTTP" || bad "fluxer edge HTTP"
fi

if stack_exists minecraft; then
  running minecraft && pass "minecraft container" || bad "minecraft container"
  tcp_ok 25565 && pass "minecraft port 25565" || bad "minecraft port 25565"
fi

if stack_exists hytale; then
  running hytale && pass "hytale container" || bad "hytale container"
  if ss -lun 2>/dev/null | grep -q ':5520 '; then
    pass "hytale port 5520/udp"
  else
    bad "hytale port 5520/udp"
  fi
fi

if stack_exists coredns; then
  running coredns && pass "coredns container" || bad "coredns container"
  if command -v dig >/dev/null 2>&1; then
    if [[ "$(dig +short @192.168.178.200 dockge.sakul-flee.de 2>/dev/null | head -n1)" == "192.168.178.200" ]]; then
      pass "coredns split-horizon answer"
    else
      bad "coredns split-horizon answer"
    fi
  fi
fi

if stack_exists wg-easy; then
  running wg-easy && pass "wg-easy container" || bad "wg-easy container"
  http_ok "http://192.168.178.200:51821/" \
    && pass "wg-easy UI" || bad "wg-easy UI"
fi

if stack_exists dockge; then
  running dockge && pass "dockge container" || bad "dockge container"
  http_ok "http://192.168.178.200:5001/" \
    && pass "dockge UI" || bad "dockge UI"
fi

if stack_exists caddy; then
  running caddy && pass "caddy container" || bad "caddy container"
fi

if ((fail)); then
  exit 1
fi

log "all checks passed"
