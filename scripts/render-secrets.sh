#!/usr/bin/env bash
# Decrypt the sops file once and render the file-based secrets the containers
# consume. Nothing is written outside /run/homelab/secrets.
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
trap 'shred -u "${tmp}" 2>/dev/null || rm -f "${tmp}"' EXIT
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

  wg_easy_password_hash

  restic_password
  restic_dendra_password
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
  printf 'PASSWORD_HASH=%s\n' "$(jq_env wg_easy_password_hash)"
} > "${wg_env}.tmp"
install -m 0400 -o root -g root "${wg_env}.tmp" "${wg_env}"
rm -f "${wg_env}.tmp"

cloudflare_ddns_env="${RUNTIME_SECRETS_DIR}/cloudflare-ddns.env"
{
  printf 'CLOUDFLARE_API_TOKEN=%s\n' "$(jq_env cloudflare_api_token)"
} > "${cloudflare_ddns_env}.tmp"
install -m 0400 -o root -g root "${cloudflare_ddns_env}.tmp" "${cloudflare_ddns_env}"
rm -f "${cloudflare_ddns_env}.tmp"

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
  capacity: 2
  timeout: 4h
  shutdown_timeout: 3m
  labels:
    - "default:docker://ghcr.io/catthehacker/ubuntu:act-24.04"
    - "ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-24.04"
    - "ubuntu-24.04:docker://ghcr.io/catthehacker/ubuntu:act-24.04"
cache:
  enabled: true
  dir: /data/cache
container:
  network: ""
  privileged: false
  valid_volumes: []
  docker_host: "-"
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

log "secret rendering complete under ${RUNTIME_SECRETS_DIR}"
