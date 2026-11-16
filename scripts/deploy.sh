#!/usr/bin/env bash
# Pull the deploy branch, validate and apply every stack, then health-check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd git
require_cmd docker
require_cmd jq

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

cd "${REPO_ROOT}"

# deploy.sh runs as root while /opt/homelab is owned by the operator, so git
# refuses with "dubious ownership" unless safe.directory is configured. Export
# the override for every git call in this script instead of relying on a
# hand-added entry in root's ~/.gitconfig, which is easy to lose.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="${REPO_ROOT}"

if ! docker network inspect proxy >/dev/null 2>&1; then
  log "creating external Docker network proxy"
  docker network create proxy >/dev/null
fi

exec 9>/run/lock/homelab-deploy.lock
if ! flock -n 9; then
  log "another deploy is already running; skipping"
  exit 0
fi

changed=0
if git fetch origin "${DEPLOY_BRANCH}" --quiet; then
  target="$(git rev-parse "origin/${DEPLOY_BRANCH}")"
  current="$(git rev-parse HEAD)"
  if [[ "${current}" != "${target}" ]]; then
    log "fast-forwarding ${current} -> ${target}"
    git merge --ff-only "origin/${DEPLOY_BRANCH}" || die "cannot fast-forward; local changes or divergence"
    changed=1
  elif [[ "${HOMELAB_DEPLOY_PENDING:-0}" == "1" ]]; then
    # Set by the re-exec below: the merge happened in the previous process.
    changed=1
  else
    log "already at ${current}"
  fi
else
  # A failed fetch (network, Forgejo down, dubious ownership) used to exit 0
  # and look like a successful no-op deploy, which hid a stale checkout for
  # hours. Report it, throttled to once per hour so a long outage does not
  # notify on every timer tick.
  log "WARN: git fetch failed; not deploying"
  stamp="${STATE_DIR}/deploy-fetch-failed.last"
  now="$(date +%s)"
  last="$(cat "${stamp}" 2>/dev/null || echo 0)"
  if (( now - last >= 3600 )); then
    notify "Deploy fetch failed" "git fetch failed on $(hostname); deploy skipped" high
    install -d -m 0755 "${STATE_DIR}"
    printf '%s\n' "${now}" > "${stamp}"
  fi
  exit 0
fi

if (( ! FORCE && ! changed )); then
  log "no new commits; nothing to deploy (use --force to re-apply)"
  exit 0
fi

# A merge can replace this script while it is running; the shell may have
# buffered the previous version, which is how a new stack was pulled but never
# applied. Re-exec once so the new code runs, keeping the pending flag.
if (( changed )) && [[ "${HOMELAB_DEPLOY_REEXEC:-0}" != "1" ]]; then
  export HOMELAB_DEPLOY_REEXEC=1 HOMELAB_DEPLOY_PENDING=1
  exec "$0" "$@"
fi

# Mirror the rest of the run to the self-hosted relay. Only actual deploys get
# here, so no-op timer runs stay quiet.
DEPLOY_LOG="$(mktemp /tmp/homelab-deploy.XXXXXX)"
exec > >(tee -a "${DEPLOY_LOG}") 2>&1
send_deploy_log() {
  local rc=$?
  sleep 0.2
  local body
  body="$(printf '[tail of deploy output]\n%s' "$(tail -c 2900 "${DEPLOY_LOG}" 2>/dev/null || true)")"
  if (( rc == 0 )); then
    notify_local "Deploy ok" "${body}" default
  else
    notify_local "Deploy FAILED" "${body}" high
  fi
  rm -f "${DEPLOY_LOG}"
}
trap send_deploy_log EXIT

"${SCRIPT_DIR}/prepare-data.sh" >/dev/null
"${SCRIPT_DIR}/render-secrets.sh"

# Validate before changing anything.
while read -r stack; do
  [[ -n "${stack}" ]] || continue
  log "validating ${stack}"
  compose "${stack}" config -q || die "invalid compose configuration: ${stack}"
done < <(stack_names)

# Local rollback point. /srv/docker is expected to be a btrfs subvolume.
if command -v btrfs >/dev/null 2>&1 && btrfs subvolume show /srv/docker >/dev/null 2>&1; then
  install -d -m 0755 /srv/snapshots
  snap="/srv/snapshots/deploy-$(date +%Y%m%dT%H%M%S)"
  btrfs subvolume snapshot -r /srv/docker "${snap}"
  log "created rollback snapshot ${snap}"
else
  log "WARN: /srv/docker is not a btrfs subvolume; skipping deploy snapshot"
fi

# Pull first, but do not abort the whole deploy if a build-only stack has no
# remote image to pull.
while read -r stack; do
  [[ -n "${stack}" ]] || continue
  case "${stack}" in
    caddy|hytale)
      log "skipping pull for build-only stack ${stack}"
      continue
      ;;
  esac
  log "pulling ${stack}"
  if ! compose "${stack}" pull; then
    log "WARN: pull failed for ${stack}; continuing with local images"
  fi
done < <(stack_names)

# Start in dependency order. Caddy is last so its upstreams exist first.
ordered_stacks=(
  coredns
  wg-easy
  dockge
  cloudflare-ddns
  forgejo
  fluxer
  minecraft
  hytale
  opencode
  syncthing
  website
  forgejo-runner
  ntfy
  caddy
)

# Staging can restrict the set, e.g.
#   DEPLOY_STACKS="forgejo minecraft hytale fluxer" scripts/deploy.sh --force
if [[ -n "${DEPLOY_STACKS:-}" ]]; then
  read -r -a ordered_stacks <<< "${DEPLOY_STACKS}"
fi

for stack in "${ordered_stacks[@]}"; do
  stack_exists "${stack}" || continue
  log "applying ${stack}"
  if ! compose "${stack}" up -d --build --remove-orphans --wait; then
    notify "Deploy failed" "Stack ${stack} failed to start" critical
    exit 1
  fi
done

# Dockge derives a stack's state from every container in the project, so a
# finished one-shot init container makes the whole stack read as "exited" even
# though every long-running service is healthy. Fluxer's seaweedfs-init has
# done its job once the stack is up, so drop the container.
if stack_exists fluxer; then
  compose fluxer rm -f seaweedfs-init >/dev/null 2>&1 || true
fi

if [[ "${SKIP_HEALTHCHECK:-0}" != "1" ]]; then
  if ! "${SCRIPT_DIR}/healthcheck.sh"; then
    notify "Deploy health check failed" "Review the host logs" critical
    exit 1
  fi
fi

notify "Deploy complete" "All stacks applied and healthy" default
