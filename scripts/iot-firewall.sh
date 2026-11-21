#!/usr/bin/env bash
# Keep the IoT Wi-Fi segment away from Docker-published ports, and NAT it out
# to the LAN interface.
#
# This unit owns the two rules ufw cannot express cleanly:
#
#  * Docker DNATs published ports in nat PREROUTING, before ufw's filter chains
#    run, so `ufw route deny ... 172.16.0.0/12` never sees those packets: by
#    the time they reach FORWARD the destination is a container address and
#    Docker's own accept rule matches. DOCKER-USER is the supported hook.
#  * ufw has no route-NAT subcommand, and a `*nat` block in
#    /etc/ufw/before.rules is restored by ufw on reload and risks flushing
#    Docker's NAT rules. Appending one matching rule to the shared POSTROUTING
#    chain touches nothing else.
#
# Docker does not flush DOCKER-USER or foreign POSTROUTING rules on a daemon
# restart, so applying this once per boot is enough. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

IFACE="${IOT_WIFI_INTERFACE:-wlp2s0}"
LAN_IF="${IOT_WIFI_LAN_IF:-eno1}"
SUBNET=192.168.179.0/24

# ufw's stock before.rules accepts ICMP echo-request in both the input and the
# forward chain before any user rule. That is why a ping from the IoT segment
# reaches the LAN and the host even though ufw-user-forward denies the same
# destinations. This base chain runs at priority -10, before ufw's filter
# chains at 0, so a drop here is final and the policy matches the docs.
nft list table inet homelab_iot >/dev/null 2>&1 || nft add table inet homelab_iot
nft list chain inet homelab_iot forward >/dev/null 2>&1 \
  || nft 'add chain inet homelab_iot forward { type filter hook forward priority -10; policy accept; }'
nft list chain inet homelab_iot input >/dev/null 2>&1 \
  || nft 'add chain inet homelab_iot input { type filter hook input priority -10; policy accept; }'
nft flush chain inet homelab_iot forward
nft flush chain inet homelab_iot input
for net in 192.168.178.0/24 100.64.0.0/10 169.254.0.0/16 10.0.0.0/8 172.16.0.0/12; do
  nft add rule inet homelab_iot forward iifname "${IFACE}" ip daddr "${net}" drop
done
nft add rule inet homelab_iot forward iifname "${IFACE}" oifname "${IFACE}" drop
# The host's own LAN address is INPUT, not FORWARD, and ufw accepts ICMP there
# too. DHCP and DNS are UDP/TCP and unaffected by this rule.
nft add rule inet homelab_iot input iifname "${IFACE}" ip protocol icmp drop

# NAT. Created even when the AP is not running: the rule matches nothing until
# the subnet has traffic, and it is cheaper than ordering against Docker.
if ! iptables -w -t nat -C POSTROUTING -s "${SUBNET}" -o "${LAN_IF}" -j MASQUERADE 2>/dev/null; then
  iptables -w -t nat -A POSTROUTING -s "${SUBNET}" -o "${LAN_IF}" -j MASQUERADE
  log "NAT ${SUBNET} -> ${LAN_IF}"
fi

# Nothing to do about Docker before it has created the chain (e.g. early boot
# or a staging host without Docker).
if ! iptables -w -n -L DOCKER-USER >/dev/null 2>&1; then
  log "DOCKER-USER is missing; Docker isolation not applied"
  exit 0
fi

for net in 172.16.0.0/12 10.0.0.0/8; do
  if ! iptables -w -C DOCKER-USER -i "${IFACE}" -d "${net}" -j DROP 2>/dev/null; then
    iptables -w -I DOCKER-USER -i "${IFACE}" -d "${net}" -j DROP
    log "blocked ${IFACE} -> ${net} in DOCKER-USER"
  fi
done
