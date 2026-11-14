#!/usr/bin/env bash
# Prepare a fresh Debian 13 host for the v2 Docker stack.
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
  btrfs-progs snapper \
  wireguard-tools nftables ufw \
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

# Optional staging policy:
# DEPLOY_STACKS="forgejo fluxer minecraft hytale coredns dockge syncthing website"
# SKIP_HEALTHCHECK=1
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
UNIT

log "writing sysctl settings"
cat >/etc/sysctl.d/90-homelab.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
SYSCTL
sysctl --system >/dev/null

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
systemctl enable --now btrfs-scrub.timer || true
systemctl enable --now smartd || true
systemctl enable --now unattended-upgrades || true
if systemctl list-unit-files snapper-timeline.timer >/dev/null 2>&1; then
  systemctl enable --now snapper-timeline.timer || true
  systemctl enable --now snapper-cleanup.timer || true
fi

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
ufw --force enable

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
else
  log "timers are installed but not enabled. Re-run with --enable-timers after verification."
fi

log "bootstrap complete"
log "next: place the sops age key, restore /srv/docker, run render-secrets.sh and deploy.sh"
