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

if stack_exists forgejo-runner; then
  running forgejo-runner && pass "forgejo-runner container" || bad "forgejo-runner container"
fi

if stack_exists openchamber; then
  running openchamber && pass "openchamber container" || bad "openchamber container"
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

if stack_exists ollama; then
  running ollama && pass "ollama container" || bad "ollama container"
  # No published port: the container lives on the `homelab-ai` network only.
  docker exec -e OLLAMA_HOST=127.0.0.1:11434 ollama ollama list >/dev/null 2>&1 \
    && pass "ollama API" || bad "ollama API"
fi

if stack_exists paperless; then
  running paperless && pass "paperless container" || bad "paperless container"
  running paperless-db && pass "paperless-db container" || bad "paperless-db container"
  running paperless-broker && pass "paperless-broker container" || bad "paperless-broker container"
  running paperless-tika && pass "paperless-tika container" || bad "paperless-tika container"
  running paperless-gotenberg && pass "paperless-gotenberg container" || bad "paperless-gotenberg container"
  # PAPERLESS_URL restricts ALLOWED_HOSTS to the public name. "localhost" is
  # always allowed for the image's own health check, so ask with that Host
  # rather than 127.0.0.1, which would be a Django 400.
  curl -fsS --max-time 5 -H 'Host: localhost' http://127.0.0.1:8000/ >/dev/null 2>&1 \
    && pass "paperless HTTP" || bad "paperless HTTP"
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

if stack_exists homeassistant; then
  running homeassistant && pass "homeassistant container" || bad "homeassistant container"
  # Home Assistant uses host networking. First boot (database creation and
  # onboarding) takes longer than the other stacks, so retry rather than fail
  # the deploy on a cold start.
  curl -fsS --max-time 5 --retry 12 --retry-delay 5 --retry-all-errors \
    http://127.0.0.1:8123/ >/dev/null 2>&1 \
    && pass "homeassistant HTTP" || bad "homeassistant HTTP"
fi

# The IoT AP is a host unit installed by bootstrap.sh. Skip until the unit
# exists, so a deploy that lands before bootstrap does not fail the run.
if systemctl cat homelab-iot-ap.service >/dev/null 2>&1; then
  if systemctl is-active --quiet homelab-iot-ap.service; then
    pass "iot AP service"
  else
    bad "iot AP service"
  fi
  if command -v iw >/dev/null 2>&1 && iw dev wlp2s0 info 2>/dev/null | grep -q 'type AP'; then
    pass "iot AP mode"
  else
    bad "iot AP mode"
  fi
  if systemctl is-active --quiet homelab-iot-dhcp.service; then
    pass "iot DHCP"
  else
    bad "iot DHCP"
  fi
  if iptables -w -t nat -C POSTROUTING -s 192.168.179.0/24 -o eno1 -j MASQUERADE 2>/dev/null; then
    pass "iot NAT"
  else
    bad "iot NAT"
  fi
  if iptables -w -C DOCKER-USER -i wlp2s0 -d 172.16.0.0/12 -j DROP 2>/dev/null; then
    pass "iot Docker isolation"
  else
    bad "iot Docker isolation"
  fi
  if nft list chain inet homelab_iot forward >/dev/null 2>&1 \
    && nft list chain inet homelab_iot input >/dev/null 2>&1; then
    pass "iot early drop"
  else
    bad "iot early drop"
  fi
  log "iot AP channel: $(cat /var/lib/homelab/iot-channel 2>/dev/null || echo unknown)"
fi

if stack_exists caddy; then
  running caddy && pass "caddy container" || bad "caddy container"
fi

if stack_exists ntfy; then
  running ntfy && pass "ntfy container" || bad "ntfy container"
  curl -fsS --max-time 25 --retry 6 --retry-delay 2 --retry-all-errors \
    --resolve ntfy.sakul-flee.de:443:127.0.0.1 \
    https://ntfy.sakul-flee.de/v1/health >/dev/null 2>&1 \
    && pass "ntfy HTTP" || bad "ntfy HTTP"
fi

if ((fail)); then
  exit 1
fi

log "all checks passed"

