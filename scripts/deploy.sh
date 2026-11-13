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
  else
    log "already at ${current}"
  fi
else
  log "WARN: git fetch failed; not deploying"
  exit 0
fi

if (( ! FORCE && ! changed )); then
  log "no new commits; nothing to deploy (use --force to re-apply)"
  exit 0
fi

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

if [[ "${SKIP_HEALTHCHECK:-0}" != "1" ]]; then
  if ! "${SCRIPT_DIR}/healthcheck.sh"; then
    notify "Deploy health check failed" "Review the host logs" critical
    exit 1
  fi
fi

notify "Deploy complete" "All stacks applied and healthy" default
