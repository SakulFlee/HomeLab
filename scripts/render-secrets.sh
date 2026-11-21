#!/usr/bin/env bash
# Decrypt the sops file once and render the file-based secrets the containers
# consume. Nothing is written outside /run/homelab/secrets, with one exception:
# /etc/hostapd/iot.conf, which has to exist at boot before the first deploy has
# rendered the runtime secrets (the AP must come back without waiting for it).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd sops
require_cmd jq

[[ -r "${SECRETS_FILE}" ]] || die "secrets file not found: ${SECRETS_FILE}"

if [[ -r /etc/sops/age/keys.txt ]]; then
  export SOPS_AGE_KEY_FILE=/etc/sops/age/keys.txt
fi

ensure_runtime_dirs
install -d -m 0700 "${RUNTIME_SECRETS_DIR}"
install -d -m 0700 "${RUNTIME_SECRETS_DIR}/forgejo"

tmp="$(mktemp /run/homelab/secrets/.decrypted.XXXXXX)"
iot_conf_tmp=""
trap 'shred -u "${tmp}" 2>/dev/null || rm -f "${tmp}"; [[ -n "${iot_conf_tmp}" ]] && rm -f "${iot_conf_tmp}"' EXIT
chmod 0600 "${tmp}"

log "decrypting ${SECRETS_FILE}"
sops -d --output-type json "${SECRETS_FILE}" > "${tmp}"

required_keys=(
  cloudflare_api_token

  forgejo_db_password
  forgejo_secret_key
  forgejo_internal_token
  forgejo_jwt_secret
  forgejo_lfs_secret
  forgejo_smtp_password
  forgejo_runner_uuid
  forgejo_runner_token

  fluxer_postgres_password
  fluxer_search_api_key
  fluxer_s3_secret_access_key
  aws_secret_access_key
  fluxer_sudo_mode_secret
  fluxer_connection_initiation_secret
  fluxer_profile_pseudonym_secret
  fluxer_gateway_rpc_auth_token
  fluxer_media_proxy_secret_key
  fluxer_media_proxy_upload_relay_secret_base64
  fluxer_admin_secret_key_base
  fluxer_admin_oauth_client_secret
  fluxer_vapid_public_key
  fluxer_vapid_private_key
  livekit_api_secret
  fluxer_erlang_cookie

  opencode_server_password
  opencode_go_api_key
  opencode_forgejo_token

  renovate_token
  renovate_github_com_token

  wg_easy_password
  wg_easy_password_hash

  ntfy_user
  ntfy_password_hash

  restic_password
  restic_dendra_password

  iot_wifi_passphrase
)

missing=()
for key in "${required_keys[@]}"; do
  if ! jq -e --arg k "${key}" 'has($k)' "${tmp}" >/dev/null 2>&1; then
    missing+=("${key}")
  fi
done
if ((${#missing[@]})); then
  die "missing sops keys: ${missing[*]}
Add them with: sops set ${SECRETS_FILE} '[\"KEY\"]' '\"VALUE\"'"
fi

write_secret() {
  local key="$1" dest="$2"
  install -d -m 0700 "$(dirname "${dest}")"
  jq -j --arg k "${key}" '.[$k]' "${tmp}" > "${dest}.tmp"
  install -m 0444 -o root -g root "${dest}.tmp" "${dest}"
  rm -f "${dest}.tmp"
}

write_secret cloudflare_api_token "${RUNTIME_SECRETS_DIR}/cloudflare_api_token"
write_secret restic_password "${RUNTIME_SECRETS_DIR}/restic-password"
write_secret restic_dendra_password "${RUNTIME_SECRETS_DIR}/restic-dendra-password"
write_secret wg_easy_password_hash "${RUNTIME_SECRETS_DIR}/wg_easy_password_hash"

write_secret forgejo_db_password "${RUNTIME_SECRETS_DIR}/forgejo/forgejo_db_password"
write_secret forgejo_secret_key "${RUNTIME_SECRETS_DIR}/forgejo/forgejo_secret_key"
write_secret forgejo_internal_token "${RUNTIME_SECRETS_DIR}/forgejo/forgejo_internal_token"
write_secret forgejo_jwt_secret "${RUNTIME_SECRETS_DIR}/forgejo/forgejo_jwt_secret"
write_secret forgejo_lfs_secret "${RUNTIME_SECRETS_DIR}/forgejo/forgejo_lfs_secret"
write_secret forgejo_smtp_password "${RUNTIME_SECRETS_DIR}/forgejo/forgejo_smtp_password"

# Compose env-file values are interpolated: a literal $ starts a variable. A
# bcrypt hash or a random token containing $ would otherwise be mangled. Escape
# every value as $$ so Compose passes the original bytes through.
env_escape() {
  sed 's/\$/$$/g'
}
jq_env() {
  jq -j --arg k "$1" '.[$k]' "${tmp}" | env_escape
}

# Raw value for files that are not Compose env files.
jq_raw() {
  jq -r --arg k "$1" '.[$k]' "${tmp}"
}

# Fluxer's upstream compose expects a .env file. Keep it root-only; Compose is
# run as root by deploy.sh and reads it via --env-file.
fluxer_env="${RUNTIME_SECRETS_DIR}/fluxer.env"
umask 077
{
  printf 'FLUXER_DOMAIN=fluxer.sakul-flee.de\n'
  printf 'FLUXER_PUBLIC_SCHEME=https\n'
  printf 'FLUXER_PUBLIC_PORT=443\n'
  printf 'FLUXER_CADDY_SITE_ADDRESS=fluxer.sakul-flee.de\n'
  printf 'FLUXER_EDGE_BIND=127.0.0.1:8080\n'
  printf 'FLUXER_EDGE_SITE_ADDRESS=:8080\n'
  # Optional upstream variables. Declaring them empty prevents Compose from
  # warning about unset values in the upstream interpolation expressions.
  printf 'FLUXER_API_NODE_HEAP_MB=\n'
  printf 'FLUXER_API_NODE_OPTIONS=\n'
  printf 'FLUXER_WORKER_NODE_HEAP_MB=\n'
  printf 'FLUXER_WORKER_NODE_OPTIONS=\n'
  printf 'FLUXER_LIVEKIT_TCP_PORT=%s\n' "${FLUXER_LIVEKIT_TCP_PORT:-7881}"
  printf 'FLUXER_LIVEKIT_UDP_PORT=%s\n' "${FLUXER_LIVEKIT_UDP_PORT:-7882}"
  printf 'LIVEKIT_API_KEY=fluxer\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$(jq_env fluxer_postgres_password)"
  printf 'MEILI_MASTER_KEY=%s\n' "$(jq_env fluxer_search_api_key)"
  printf 'FLUXER_S3_ACCESS_KEY=fluxer\n'
  printf 'FLUXER_S3_SECRET_KEY=%s\n' "$(jq_env fluxer_s3_secret_access_key)"
  printf 'AWS_ACCESS_KEY_ID=fluxer\n'
  printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$(jq_env aws_secret_access_key)"
  printf 'FLUXER_SUDO_MODE_SECRET=%s\n' "$(jq_env fluxer_sudo_mode_secret)"
  printf 'FLUXER_CONNECTION_INITIATION_SECRET=%s\n' "$(jq_env fluxer_connection_initiation_secret)"
  printf 'FLUXER_PROFILE_PSEUDONYM_SECRET=%s\n' "$(jq_env fluxer_profile_pseudonym_secret)"
  printf 'FLUXER_GATEWAY_RPC_AUTH_TOKEN=%s\n' "$(jq_env fluxer_gateway_rpc_auth_token)"
  printf 'FLUXER_MEDIA_PROXY_SECRET_KEY=%s\n' "$(jq_env fluxer_media_proxy_secret_key)"
  printf 'FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64=%s\n' "$(jq_env fluxer_media_proxy_upload_relay_secret_base64)"
  printf 'FLUXER_ADMIN_SECRET_KEY_BASE=%s\n' "$(jq_env fluxer_admin_secret_key_base)"
  printf 'FLUXER_ADMIN_OAUTH_CLIENT_SECRET=%s\n' "$(jq_env fluxer_admin_oauth_client_secret)"
  printf 'FLUXER_VAPID_PUBLIC_KEY=%s\n' "$(jq_env fluxer_vapid_public_key)"
  printf 'FLUXER_VAPID_PRIVATE_KEY=%s\n' "$(jq_env fluxer_vapid_private_key)"
  printf 'LIVEKIT_API_SECRET=%s\n' "$(jq_env livekit_api_secret)"
  printf 'FLUXER_ERLANG_COOKIE=%s\n' "$(jq_env fluxer_erlang_cookie)"
} > "${fluxer_env}.tmp"
install -m 0400 -o root -g root "${fluxer_env}.tmp" "${fluxer_env}"
rm -f "${fluxer_env}.tmp"

# Environment files for the remaining containers. These are not mounted into
# images; they are passed to `docker compose` or used by systemd.
opencode_env="${RUNTIME_SECRETS_DIR}/opencode.env"
{
  printf 'OPENCODE_SERVER_PASSWORD=%s\n' "$(jq_env opencode_server_password)"
  printf 'OPENCODE_API_KEY=%s\n' "$(jq_env opencode_go_api_key)"
  printf 'FORGEJO_TOKEN=%s\n' "$(jq_env opencode_forgejo_token)"
} > "${opencode_env}.tmp"
install -m 0400 -o root -g root "${opencode_env}.tmp" "${opencode_env}"
rm -f "${opencode_env}.tmp"

renovate_env="${RUNTIME_SECRETS_DIR}/renovate.env"
{
  printf 'RENOVATE_TOKEN=%s\n' "$(jq_env renovate_token)"
  printf 'RENOVATE_GITHUB_COM_TOKEN=%s\n' "$(jq_env renovate_github_com_token)"
} > "${renovate_env}.tmp"
install -m 0400 -o root -g root "${renovate_env}.tmp" "${renovate_env}"
rm -f "${renovate_env}.tmp"

runner_env="${RUNTIME_SECRETS_DIR}/forgejo-runner.env"
{
  printf 'RUNNER_UUID=%s\n' "$(jq_env forgejo_runner_uuid)"
  printf 'RUNNER_TOKEN=%s\n' "$(jq_env forgejo_runner_token)"
} > "${runner_env}.tmp"
install -m 0400 -o root -g root "${runner_env}.tmp" "${runner_env}"
rm -f "${runner_env}.tmp"

wg_env="${RUNTIME_SECRETS_DIR}/wg-easy.env"
{
  # v15 ignores PASSWORD_HASH and treats its presence as an unmigrated v14
  # configuration, so only the one-time INIT_* values are written here.
  printf 'INIT_USERNAME=%s\n' "admin"
  printf 'INIT_PASSWORD=%s\n' "$(jq_env wg_easy_password)"
} > "${wg_env}.tmp"
install -m 0400 -o root -g root "${wg_env}.tmp" "${wg_env}"
rm -f "${wg_env}.tmp"

cloudflare_ddns_env="${RUNTIME_SECRETS_DIR}/cloudflare-ddns.env"
{
  printf 'CLOUDFLARE_API_TOKEN=%s\n' "$(jq_env cloudflare_api_token)"
} > "${cloudflare_ddns_env}.tmp"
install -m 0400 -o root -g root "${cloudflare_ddns_env}.tmp" "${cloudflare_ddns_env}"
rm -f "${cloudflare_ddns_env}.tmp"

# Concurrency is a host setting, not a secret: it depends on cores and RAM.
# Set FORGEJO_RUNNER_CAPACITY in /etc/homelab/host.env to change it.
runner_capacity="${FORGEJO_RUNNER_CAPACITY:-2}"
[[ "${runner_capacity}" =~ ^[0-9]+$ ]] \
  || die "FORGEJO_RUNNER_CAPACITY must be a whole number, got '${runner_capacity}'"

runner_dir="${RUNTIME_SECRETS_DIR}/forgejo-runner"
install -d -m 0700 "${runner_dir}"
runner_uuid="$(jq -j --arg k forgejo_runner_uuid '.[$k]' "${tmp}")"
runner_token="$(jq -j --arg k forgejo_runner_token '.[$k]' "${tmp}")"
cat > "${runner_dir}/config.yaml.tmp" <<EOF
log:
  level: info
  job_level: info
runner:
  file: /data/.runner
  capacity: ${runner_capacity}
  timeout: 4h
  shutdown_timeout: 3m
  labels:
    - "default:docker://ghcr.io/catthehacker/ubuntu:act-24.04"
    - "ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-24.04"
    - "ubuntu-24.04:docker://ghcr.io/catthehacker/ubuntu:act-24.04"
    - "docker:docker://ghcr.io/catthehacker/ubuntu:act-24.04"
cache:
  enabled: true
  dir: /data/cache
container:
  # Job containers must reach Forgejo by its compose name. On the default
  # bridge that name does not resolve, so checkout fails with "could not
  # connect to server". The proxy network is where forgejo, caddy and the
  # other stacks are attached.
  network: "proxy"
  privileged: false
  valid_volumes: []
  docker_host: "automount"
  workdir_parent: /data/workspace
server:
  connections:
    forgejo:
      url: http://forgejo:3000
      uuid: "${runner_uuid}"
      token: "${runner_token}"
EOF
install -m 0400 -o root -g root "${runner_dir}/config.yaml.tmp" "${runner_dir}/config.yaml"
rm -f "${runner_dir}/config.yaml.tmp"

# Local, gitignored Compose .env files. These make Dockge/Start and manual
# `docker compose` in a stack directory use the same host-specific values as
# deploy.sh. They are never committed.
env_group=root
if getent group docker >/dev/null 2>&1; then
  env_group=docker
fi

write_stack_env() {
  local stack="$1"
  shift
  local file="${REPO_ROOT}/stacks/${stack}/.env"
  "$@" > "${file}.tmp"
  install -m 0640 -o root -g "${env_group}" "${file}.tmp" "${file}"
  rm -f "${file}.tmp"
}

# Fluxer has a complete secret environment.
install -m 0640 -o root -g "${env_group}" "${fluxer_env}" \
  "${REPO_ROOT}/stacks/fluxer/.env"

write_stack_env forgejo \
  printf 'FORGEJO_SSH_HOST_PORT=%s\n' "${FORGEJO_SSH_HOST_PORT:-22}"

write_stack_env minecraft \
  printf 'MINECRAFT_PORT=%s\n' "${MINECRAFT_PORT:-25565}"

write_stack_env hytale \
  printf 'HYTALE_PORT=%s\n' "${HYTALE_PORT:-5520}"

for stack in coredns dockge syncthing; do
  write_stack_env "${stack}" \
    printf 'LAN_IP=%s\n' "${LAN_IP:-192.168.178.200}"
done

write_stack_env caddy \
  printf 'LAN_IP=%s\nHTTP_PORT=%s\nHTTPS_PORT=%s\nACME_CA=%s\n' \
  "${LAN_IP:-192.168.178.200}" "${HTTP_PORT:-80}" "${HTTPS_PORT:-443}" \
  "${ACME_CA:-https://acme-v02.api.letsencrypt.org/directory}"

# Optional notification endpoints. Missing keys simply disable that channel;
# none of them is required for the host to operate.
notify_env=/etc/homelab/notify.env
notify_tmp="$(mktemp /etc/homelab/.notify.XXXXXX)"
{
  for key in ntfy_url ntfy_fallback_url ntfy_user ntfy_password fluxer_webhook_url healthchecks_check_url healthchecks_pull_url; do
    if jq -e --arg k "${key}" 'has($k) and (.[$k] != "")' "${tmp}" >/dev/null 2>&1; then
      printf '%s=%s\n' "${key^^}" "$(jq -r --arg k "${key}" '.[$k]' "${tmp}")"
    fi
  done
} > "${notify_tmp}"
install -m 0600 -o root -g root "${notify_tmp}" "${notify_env}"
rm -f "${notify_tmp}"

# ntfy access control. ntfy 2.38 stores users in SQLite and provisions them
# declaratively; env_file passes the bcrypt hash through without Compose
# trying to interpolate its '$' characters.
ntfy_env="${RUNTIME_SECRETS_DIR}/ntfy.env"
ntfy_user="$(jq_raw ntfy_user)"
{
  printf 'NTFY_AUTH_USERS=%s:%s:user\n' "${ntfy_user}" "$(jq_raw ntfy_password_hash)"
  printf 'NTFY_AUTH_ACCESS=%s:homelab:rw\n' "${ntfy_user}"
} > "${ntfy_env}.tmp"
install -m 0400 -o root -g root "${ntfy_env}.tmp" "${ntfy_env}"
rm -f "${ntfy_env}.tmp"

# IoT AP. hostapd cannot read a passphrase from a file, so the whole config is
# generated, including the WPA-PSK. It is written to /etc, not /run, because
# the AP must return on boot before the first deploy has rendered /run secrets.
iot_passphrase="$(jq -j --arg k iot_wifi_passphrase '.[$k]' "${tmp}")"
[[ "${iot_passphrase}" =~ ^[A-Za-z0-9]{8,63}$ ]] \
  || die "iot_wifi_passphrase must be 8-63 alphanumeric characters (cheap IoT firmware mishandles punctuation)"

iot_ssid="${IOT_WIFI_SSID:-HomeLab-IoT}"
iot_iface="${IOT_WIFI_INTERFACE:-wlp2s0}"
# iot-channel.sh replaces this at AP start when the setting is auto. Validate
# it here as well so a typo fails the deploy instead of every AP start.
case "${IOT_WIFI_CHANNEL:-auto}" in
  auto) iot_channel=1 ;;
  1|6|11) iot_channel="${IOT_WIFI_CHANNEL}" ;;
  *) die "IOT_WIFI_CHANNEL must be auto, 1, 6 or 11 (got '${IOT_WIFI_CHANNEL}')" ;;
esac

install -d -m 0755 /etc/hostapd
iot_conf=/etc/hostapd/iot.conf
iot_conf_tmp="$(mktemp /etc/hostapd/.iot.conf.XXXXXX)"
cat >"${iot_conf_tmp}" <<EOF
# Generated by scripts/render-secrets.sh -- do not edit.
# The passphrase comes from sops (iot_wifi_passphrase). The channel line is
# replaced at AP start by scripts/iot-channel.sh unless IOT_WIFI_CHANNEL is
# pinned in /etc/homelab/host.env.
interface=${iot_iface}
driver=nl80211

ssid=${iot_ssid}
country_code=DE
ieee80211d=1

hw_mode=g
channel=${iot_channel}
ieee80211n=1
ieee80211ax=0
wmm_enabled=1
beacon_int=100
dtim_period=2
ap_max_inactivity=600
disassoc_low_ack=0
max_num_sta=32
ap_isolate=0

auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_group_rekey=86400
ieee80211w=0

logger_syslog=-1
logger_syslog_level=2
wpa_passphrase=${iot_passphrase}
EOF
chmod 0600 "${iot_conf_tmp}"

iot_changed=0
if cmp -s "${iot_conf_tmp}" "${iot_conf}"; then
  rm -f "${iot_conf_tmp}"
  iot_conf_tmp=""
else
  install -m 0600 -o root -g root "${iot_conf_tmp}" "${iot_conf}"
  rm -f "${iot_conf_tmp}"
  iot_conf_tmp=""
  iot_changed=1
fi

# The AP is a host unit, not a Compose stack, so a secrets change does not
# restart it through Compose. Restart only when the config actually changed,
# or start it when it is enabled but not running yet.
if systemctl cat homelab-iot-ap.service >/dev/null 2>&1; then
  if ((iot_changed)) || ! systemctl is-active --quiet homelab-iot-ap.service; then
    systemctl restart homelab-iot-ap.service \
      || log "WARN: could not restart homelab-iot-ap.service"
  fi
fi

log "secret rendering complete under ${RUNTIME_SECRETS_DIR}"
