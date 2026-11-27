#!/usr/bin/env bash
# Prepare a fresh Debian 13 host for the Docker stack.
#
# Idempotent where possible. It does not write secrets, restore data, or start
# application stacks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd apt-get

if [[ ! -r /etc/os-release ]]; then
  die "cannot identify the OS"
fi
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "this bootstrap expects Debian (found ${ID:-unknown})"

ENABLE_TIMERS=0
if [[ "${1:-}" == "--enable-timers" ]]; then
  ENABLE_TIMERS=1
fi

log "installing base packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg git jq \
  age restic \
  btrfs-progs btrfsmaintenance snapper \
  wireguard-tools nftables ufw iptables \
  hostapd iw dnsmasq-base \
  dnsutils netcat-openbsd \
  tmux htop btop smartmontools zram-tools unattended-upgrades

if ! command -v sops >/dev/null 2>&1; then
  # sops is not in Debian trixie. Use the upstream Debian package and pin the
  # version here so a rebuild is reproducible.
  SOPS_VERSION="${SOPS_VERSION:-3.12.2}"
  log "installing sops ${SOPS_VERSION} from the upstream release"
  tmpdir="$(mktemp -d)"
  curl -fsSL \
    "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops_${SOPS_VERSION}_$(dpkg --print-architecture).deb" \
    -o "${tmpdir}/sops.deb"
  dpkg -i "${tmpdir}/sops.deb" || DEBIAN_FRONTEND=noninteractive apt-get -f install -y
  rm -rf "${tmpdir}"
fi

log "configuring the Docker apt repository"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "creating directories"
install -d -m 0755 /opt /srv/docker /srv/backup /srv/snapshots
install -d -m 0755 /srv/backup/dumps /srv/backup/repo-snapshots
if ! btrfs subvolume show /srv/backup/restic >/dev/null 2>&1; then
  btrfs subvolume create /srv/backup/restic >/dev/null 2>&1 \
    || install -d -m 0755 /srv/backup/restic
fi
install -d -m 0700 /var/lib/homelab
install -d -m 0700 /run/homelab/secrets
install -d -m 0700 /etc/sops/age
install -d -m 0700 /etc/homelab
if [[ ! -f /etc/homelab/host.env ]]; then
  cat >/etc/homelab/host.env <<'HOSTENV'
# Non-secret host-specific settings. Override per-host or for staging.
LAN_IP=192.168.178.200
FORGEJO_SSH_HOST_PORT=22
MINECRAFT_PORT=25565
HYTALE_PORT=5520
HTTP_PORT=80
HTTPS_PORT=443
FLUXER_LIVEKIT_TCP_PORT=7881
FLUXER_LIVEKIT_UDP_PORT=7882

# IoT Wi-Fi AP (see docs/iot-wifi.md). The interface comes up as
# 192.168.179.1/24 and is isolated from the LAN. Channel: auto, 1, 6 or 11.
IOT_WIFI_SSID=HomeLab-IoT
IOT_WIFI_CHANNEL=auto
IOT_WIFI_INTERFACE=wlp2s0

# Forgejo runner concurrency (parallel jobs). Raise it with cores and RAM.
FORGEJO_RUNNER_CAPACITY=2
# Memory cap per job container, including swap, so a build cannot push the
# host into swap. The iGPU holds the local Ollama model in system RAM and
# swapped-out GPU pages make inference return garbage (see AGENTS.md). It
# multiplies with capacity: 2 x 12g does not fit here, so heavy builds want
# FORGEJO_RUNNER_CAPACITY=1 or a lower value. `none` leaves jobs uncapped.
FORGEJO_RUNNER_JOB_MEMORY=12g

# Optional staging policy:
# DEPLOY_STACKS="forgejo fluxer minecraft hytale coredns dockge syncthing website"
# SKIP_HEALTHCHECK=1

# Caddy ACME directory. Uncomment to use Let's Encrypt staging while
# validating DNS and port forwards, then remove for production certs.
# ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory
HOSTENV
  chmod 0600 /etc/homelab/host.env
fi
cat >/etc/tmpfiles.d/homelab.conf <<'TMPFILES'
d /run/homelab 0700 root root -
d /run/homelab/secrets 0700 root root -
TMPFILES

log "writing Docker daemon configuration"
install -d -m 0755 /etc/docker
cat >/etc/docker/daemon.json <<'JSON'
{
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "data-root": "/var/lib/docker"
}
JSON

log "ordering Docker after the data mount"
install -d -m 0755 /etc/systemd/system/docker.service.d
cat >/etc/systemd/system/docker.service.d/10-homelab.conf <<'UNIT'
[Unit]
RequiresMountsFor=/srv/docker

[Service]
# Containers that bind-mount /var/run/docker.sock keep the inode that existed
# when they were created. dockerd replaces the socket on every restart, and
# live-restore keeps those containers running, so the runner fails every job
# with "Cannot connect to the Docker daemon" until it is restarted. Re-check
# the socket consumers as soon as the daemon is up again.
ExecStartPost=-/opt/homelab/scripts/docker-socket-refresh.sh
UNIT

log "writing sysctl settings"
cat >/etc/sysctl.d/90-homelab.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
# Required by wg-easy's fwmark routing. It cannot be set from the container
# because Docker rejects sysctls in the host network namespace.
net.ipv4.conf.all.src_valid_mark = 1
# wg-easy 15 hands out IPv6 tunnel addresses and expects to route them.
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
# Publish exactly one IPv6 address through DDNS. Privacy addresses rotate and
# would make the AAAA record churn every few minutes. The per-interface value
# overrides 'all', so both are set.
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
net.ipv6.conf.eno1.use_tempaddr = 0
# The IoT AP is IPv4-only on purpose: the LAN's IPv6 prefix must not leak
# onto it, and there is no IPv6 firewall policy for that segment.
net.ipv6.conf.wlp2s0.disable_ipv6 = 1
# IoT clients must not be told about a LAN next hop.
net.ipv4.conf.wlp2s0.send_redirects = 0
net.ipv4.conf.wlp2s0.accept_redirects = 0
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
SYSCTL
sysctl --system >/dev/null

log "configuring the IoT Wi-Fi access point"
install -d -m 0755 /etc/hostapd /etc/NetworkManager/conf.d \
  /etc/network/interfaces.d /etc/modprobe.d

# Keep NetworkManager away from the AP interface. ifupdown owns it (below),
# and NetworkManager.conf already sets managed=false for ifupdown-managed
# interfaces; this drop-in also covers a profile appearing later.
cat >/etc/NetworkManager/conf.d/99-homelab-iot.conf <<'NMIOT'
[keyfile]
unmanaged-devices=interface-name:wlp2s0
NMIOT

# The MT7921 is a client-oriented part. ASPM causes high latency and the odd
# firmware stall, which on an AP shows up as clients dropping off. Takes effect
# on the next boot; the module cannot be unloaded while the radio is in use.
cat >/etc/modprobe.d/mt7921e.conf <<'MODPROBE'
options mt7921e disable_aspm=1
MODPROBE

# ifupdown brings the interface up with its address before hostapd switches it
# to AP mode. The subnet must match the ufw route rules and the NAT block.
cat >/etc/network/interfaces.d/iot-ap <<'IFACE'
# IoT Wi-Fi AP (wlp2s0). hostapd owns the radio; this only assigns the
# gateway address. See docs/iot-wifi.md.
auto wlp2s0
iface wlp2s0 inet static
    address 192.168.179.1/24
IFACE

# Dedicated dnsmasq instance. dnsmasq-base is installed (NetworkManager pulls
# it in) but ships no global service, so this cannot collide with the CoreDNS
# container bound to 192.168.178.200:53.
cat >/etc/dnsmasq-iot.conf <<'DNSMASQ'
# Served only on the IoT AP interface.
interface=wlp2s0
bind-dynamic

dhcp-range=192.168.179.50,192.168.179.200,255.255.255.0,24h
dhcp-option=option:router,192.168.179.1
dhcp-option=option:dns-server,192.168.179.1
dhcp-authoritative
dhcp-leasefile=/var/lib/misc/dnsmasq-iot.leases

# Never read /etc/resolv.conf: NetworkManager rewrites it, and the IoT subnet
# cannot reach the host's resolver anyway. Ask the router, with a public
# resolver as the backup.
no-resolv
server=192.168.178.1
server=9.9.9.9
domain-needed
bogus-priv

log-dhcp
log-facility=-
DNSMASQ

# dnsmasq drops to the dnsmasq user, so it must own its lease file.
if [[ ! -e /var/lib/misc/dnsmasq-iot.leases ]]; then
  install -m 0644 -o dnsmasq -g nogroup /dev/null /var/lib/misc/dnsmasq-iot.leases
fi
chown dnsmasq:nogroup /var/lib/misc/dnsmasq-iot.leases
chmod 0644 /var/lib/misc/dnsmasq-iot.leases

systemctl reload NetworkManager 2>/dev/null || true
# The packaged unit reads /etc/hostapd/hostapd.conf and would fight our one
# instance. It is not enabled by default, but make that explicit.
systemctl disable --now hostapd.service 2>/dev/null || true

log "installing systemd units"
if compgen -G "${REPO_ROOT}/systemd/*.service" >/dev/null; then
  install -m 0644 "${REPO_ROOT}"/systemd/*.service /etc/systemd/system/
fi
if compgen -G "${REPO_ROOT}/systemd/*.timer" >/dev/null; then
  install -m 0644 "${REPO_ROOT}"/systemd/*.timer /etc/systemd/system/
fi
if compgen -G "${REPO_ROOT}/systemd/*.path" >/dev/null; then
  install -m 0644 "${REPO_ROOT}"/systemd/*.path /etc/systemd/system/
fi
chmod 0755 "${REPO_ROOT}"/scripts/*.sh || true
"${REPO_ROOT}/scripts/prepare-data.sh"
systemctl daemon-reload

log "enabling base services"
systemctl enable --now docker
systemctl enable --now fstrim.timer || true
# btrfs-progs on trixie ships no timers; btrfsmaintenance provides the scrub
# unit. Its default config already scrubs monthly and leaves balance, trim and
# defrag to "none" (fstrim.timer above covers discards). Only the mountpoints
# need adjusting: "/" is btrfs and /srv/backup is a second, LUKS-backed btrfs.
if [[ -f /etc/default/btrfsmaintenance ]]; then
  sed -i 's|^BTRFS_SCRUB_MOUNTPOINTS=.*|BTRFS_SCRUB_MOUNTPOINTS="/ /srv/backup"|' \
    /etc/default/btrfsmaintenance
fi
systemctl enable --now btrfs-scrub.timer || true
# smartd is only an alias shipped in /etc/systemd/system; `systemctl enable`
# refuses to operate on it. The real unit is smartmontools.service.
systemctl enable --now smartmontools.service || true
systemctl enable --now unattended-upgrades || true
if systemctl list-unit-files snapper-timeline.timer >/dev/null 2>&1; then
  systemctl enable --now snapper-timeline.timer || true
  systemctl enable --now snapper-cleanup.timer || true
fi

# The AP only starts once render-secrets.sh has written its config; enabling
# here is enough, and the unit itself is started below, after the firewall
# rules exist.
systemctl enable homelab-iot-firewall.service \
  homelab-iot-ap.service homelab-iot-dhcp.service

log "creating the proxy network"
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

log "configuring the host firewall"
ufw --force default deny incoming
ufw --force default allow outgoing
# Public services.
ufw allow 22/tcp comment 'Forgejo Git SSH'
ufw allow 80/tcp comment 'Caddy HTTP'
ufw allow 443/tcp comment 'Caddy HTTPS'
ufw allow 25565/tcp comment 'Minecraft'
ufw allow 5520/udp comment 'Hytale'
ufw allow 7881/tcp comment 'Fluxer LiveKit TCP'
ufw allow 7882/udp comment 'Fluxer LiveKit UDP'
ufw allow 51820/udp comment 'WireGuard'
# Host administration and LAN/VPN-only services.
for net in 192.168.178.0/24 100.64.0.0/10; do
  ufw allow from "${net}" to any port 2222 proto tcp comment 'Host SSH'
  ufw allow from "${net}" to any port 53 proto udp comment 'CoreDNS UDP'
  ufw allow from "${net}" to any port 53 proto tcp comment 'CoreDNS TCP'
  ufw allow from "${net}" to any port 5001 proto tcp comment 'Dockge'
  ufw allow from "${net}" to any port 51821 proto tcp comment 'wg-easy'
  ufw allow from "${net}" to any port 4096 proto tcp comment 'OpenCode'
  ufw allow from "${net}" to any port 8384 proto tcp comment 'Syncthing'
done
# Caddy runs in a bridge network and reaches wg-easy (host networking) via the
# host's LAN address, so the source is the Docker bridge, not the LAN.
ufw allow from 172.16.0.0/12 to any port 51821 proto tcp comment 'wg-easy from Caddy'
ufw allow from 172.16.0.0/12 to any port 8123 proto tcp comment 'Home Assistant from Caddy'
# wg0 is created by wg-easy after ufw starts, and wg-easy writes its forwarding
# rules with iptables-legacy. ufw's policy lives in nftables, so without this
# route rule every NEW forwarded connection from a VPN client is dropped --
# ICMP still passes because ufw accepts it in ufw-before-forward, which makes
# the failure look like a routing problem.
ufw route allow in on wg0 comment 'WireGuard clients'

# IoT Wi-Fi segment. DHCP and DNS are the only things it may reach on the host;
# everything else is in ufw's default deny.
ufw allow in on wlp2s0 to any port 67 proto udp comment 'IoT DHCP'
ufw allow in on wlp2s0 to any port 53 proto udp comment 'IoT DNS'
ufw allow in on wlp2s0 to any port 53 proto tcp comment 'IoT DNS'

# Deny the private destinations first, then allow the internet. ufw evaluates
# user-forward rules in insertion order, so the order here is the policy.
for net in 192.168.178.0/24 100.64.0.0/10 169.254.0.0/16 10.0.0.0/8 172.16.0.0/12; do
  ufw route deny in on wlp2s0 to "${net}" comment 'IoT isolation'
done
ufw route deny in on wlp2s0 out on wlp2s0 comment 'IoT client isolation'
ufw route allow in on wlp2s0 out on eno1 comment 'IoT internet'

ufw --force enable

# Now that the isolation rules are in place, bring the AP up. The NAT and
# DOCKER-USER rules live in homelab-iot-firewall.service; hostapd's config is
# rendered by render-secrets.sh, which may not have run yet on a fresh host.
systemctl start homelab-iot-firewall.service || true
if [[ -r /etc/hostapd/iot.conf ]]; then
  systemctl restart homelab-iot-ap.service \
    || log "WARN: IoT AP did not start; check journalctl -u homelab-iot-ap"
else
  log "IoT AP config not rendered yet; run render-secrets.sh to start it"
fi

if [[ ! -s /etc/sops/age/keys.txt ]]; then
  log "WARNING: /etc/sops/age/keys.txt is missing."
  log "Place the age identity there before running render-secrets.sh."
fi

if ((ENABLE_TIMERS)); then
  log "enabling deploy/backup timers"
  systemctl enable --now homelab-deploy.timer || true
  systemctl enable --now homelab-backup.timer || true
  systemctl enable --now homelab-restic-copy.timer || true
  systemctl enable --now homelab-restic-check.timer || true
  systemctl enable --now homelab-renovate.timer || true
  systemctl enable --now homelab-docker-cleanup.timer || true
  systemctl enable --now homelab-runner-cleanup.timer || true
else
  log "timers are installed but not enabled. Re-run with --enable-timers after verification."
fi

log "bootstrap complete"
log "next: place the sops age key, restore /srv/docker, run render-secrets.sh and deploy.sh"
