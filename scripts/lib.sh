#!/usr/bin/env bash
# Shared helpers for the v2 host scripts. Source this file; do not execute it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACKS_DIR="${REPO_ROOT}/stacks"
SECRETS_FILE="${SECRETS_FILE:-${REPO_ROOT}/secrets/secrets.yaml}"
RUNTIME_SECRETS_DIR="${RUNTIME_SECRETS_DIR:-/run/homelab/secrets}"
STATE_DIR="${STATE_DIR:-/var/lib/homelab}"
BACKUP_DIR="${BACKUP_DIR:-/srv/backup}"
LIVE_DATA_DIR="${LIVE_DATA_DIR:-/srv/docker}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-v2}"

# Host-specific, non-secret settings: bind addresses, host port mappings and
# optional deploy policy. Production uses /etc/homelab/host.env; staging can
# point HOMELAB_ENV_FILE at a different file.
HOST_ENV_FILE="${HOMELAB_ENV_FILE:-/etc/homelab/host.env}"
if [[ -r "${HOST_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${HOST_ENV_FILE}"
  set +a
fi

log() {
  printf '%s %s\n' "$(date -Is)" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "run this script as root"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ensure_runtime_dirs() {
  install -d -m 0700 "${RUNTIME_SECRETS_DIR}"
  install -d -m 0755 "${STATE_DIR}"
}

notify() {
  local title="$1" message="$2" priority="${3:-default}"
  log "${title}: ${message}"
  if [[ -n "${NTFY_URL:-}" ]] && command -v curl >/dev/null 2>&1; then
    curl -fsS -m 10 \
      -H "Title: ${title}" \
      -H "Priority: ${priority}" \
      -d "${message}" \
      "${NTFY_URL}" >/dev/null 2>&1 || true
  fi
}

stack_exists() {
  [[ -f "${STACKS_DIR}/$1/compose.yaml" ]]
}

stack_names() {
  find "${STACKS_DIR}" -mindepth 2 -maxdepth 2 -name compose.yaml \
    -printf '%h\n' | xargs -r -n1 basename | sort
}

# Compose files for a stack. Most stacks have a single compose.yaml; Fluxer
# keeps the upstream files under vendor/ and adds an override.
compose_args() {
  local stack="$1"
  local dir="${STACKS_DIR}/${stack}"

  printf '%s\n' -f "${dir}/compose.yaml"
}

compose() {
  local stack="$1"
  shift
  local -a args
  mapfile -t args < <(compose_args "${stack}")
  local -a env_args=()
  case "${stack}" in
    fluxer)
      env_args=(--env-file "${RUNTIME_SECRETS_DIR}/fluxer.env")
      ;;
  esac
  docker compose --project-directory "${STACKS_DIR}/${stack}" \
    "${args[@]}" "${env_args[@]}" "$@"
}
