#!/usr/bin/env bash
#
# Render the host's sops secrets into the running Incus instances.
#
# This is the small remainder of incus/apply.sh that OpenTofu cannot own.
# Terraform can create instances, volumes and images, and it can upload a file
# whose *content* is part of the resource, but that would put plaintext secrets
# in tfstate. A `source_path` upload keeps the bytes out of state and then never
# notices the file changing, so a rotated token would silently not be deployed.
#
# The host is the only thing that can decrypt, so the host does the rendering.
# The guest still receives bytes and no decryption capability, exactly as
# before: a root process inside an instance cannot read any other value from
# nixos/secrets.yaml.
#
# Input is the generated spec bundle (INCUS_SECRETS_SPECS):
#
#   { "instances": { "<name>": <incus.nix spec>, ... },
#     "projects":  { "<name>": "<project>", ... } }
#
# Run by incus-secrets.service (boot, /run/secrets change, and a timer).
set -Eeuo pipefail

SPECS_FILE=${INCUS_SECRETS_SPECS:?INCUS_SECRETS_SPECS must name the spec bundle}
TAG=incus-secrets

log()  { printf '%-14s %s\n' "$TAG" "$*" >&2; }
step() { printf '%-14s == %s\n' "$TAG" "$*" >&2; }
warn() { printf '%-14s WARN: %s\n' "$TAG" "$*" >&2; }
die()  { printf '%-14s ERROR: %s\n' "$TAG" "$*" >&2; exit 1; }

PROJECT=""

project_qs() {
  [[ -n $PROJECT ]] && printf '?project=%s' "$PROJECT" || printf ''
}

incus_run() {
  local -a pargs=()
  [[ -n $PROJECT ]] && pargs=(--project "$PROJECT")
  log "incus ${pargs[*]} $*"
  incus "${pargs[@]}" "$@" </dev/null
}

incus_run_stdin() {
  local -a pargs=()
  [[ -n $PROJECT ]] && pargs=(--project "$PROJECT")
  log "incus ${pargs[*]} $*"
  incus "${pargs[@]}" "$@"
}

# Trust operations are host-global; --project is not meaningful there.
incus_global() {
  log "incus $*"
  incus "$@" </dev/null
}

# Read from a guest without the noise of a logged exec. An absent file, a
# stopped guest and a missing coreutils all read as empty, and callers treat
# empty as "needs writing"; the write is what reports a real failure.
guest_read() {
  local iname=$1
  shift
  local -a pargs=()
  [[ -n $PROJECT ]] && pargs=(--project "$PROJECT")
  incus "${pargs[@]}" exec "$iname" -- \
    sh -c "export PATH=/run/current-system/sw/bin:\$PATH; $*" 2>/dev/null || true
}

# A key present in secrets.yaml but not declared as sops.secrets.<name> is never
# written to /run/secrets, and no rebuild can change that. Distinguish that from
# a permissions problem, because the two send you to different places.
assert_secret_readable() {
  local source=$1 what=$2
  if [[ ! -e $source ]]; then
    die "$source does not exist, so $what cannot be rendered." \
        "sops-nix only writes a secret to /run/secrets if the host declares" \
        "sops.secrets.$(basename "$source") in nixos/modules/sops.nix. Check the" \
        "key is both present in secrets.yaml AND declared there -- a rebuild" \
        "cannot create a file nothing asks for."
  fi
  [[ -r $source ]] || die "$source exists but is not readable, so $what cannot" \
                           "be rendered. That is a permissions problem on the" \
                           "host, not a missing declaration."
}

render_secrets() {
  local name=$1 spec=$2 entry file env format mode group source value wanted
  local path dir cur_mode cur_group cur_dir_mode state cmd attempt needs_write
  local dir_owner current_sum want_sum
  local changed=0
  local -a entries consumers

  mapfile -t entries < <(jq -c '.renderedSecrets[]?' <<<"$spec")
  if [[ ${#entries[@]} -eq 0 ]]; then
    return 0
  fi

  [[ $EUID -eq 0 ]] || die "$name declares renderedSecrets but incus-secrets is not root"

  for entry in "${entries[@]}"; do
    file=$(jq -r '.file // empty' <<<"$entry")
    format=$(jq -r '.format // "env"' <<<"$entry")
    env=$(jq -r '.env // empty' <<<"$entry")
    mode=$(jq -r '.mode // "0400"' <<<"$entry")
    group=$(jq -r '.group // empty' <<<"$entry")
    source=$(jq -r '.source // empty' <<<"$entry")

    [[ -n $file ]] || die "$name has a renderedSecret with no file name: $entry"
    [[ -n $source ]] || die "$name's $file has no source: $entry"

    # file, mode and group are interpolated into a guest shell command below.
    [[ $file =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      || die "$name's renderedSecret has an unusable file name '$file'"
    [[ $mode =~ ^[0-7]{3,4}$ ]] \
      || die "$name's $file has mode '$mode', which is not octal (want e.g. 0440)"
    [[ -z $group || $group =~ ^[a-z_][a-z0-9_-]*\$?$ ]] \
      || die "$name's $file has an invalid group '$group'"

    case $format in
      env)
        [[ -n $env ]] || die "$name's $file uses format=env but declares no env name"
        ;;
      raw) ;;
      *) die "$name's $file has unknown format '$format' (want env or raw)" ;;
    esac

    assert_secret_readable "$source" "$name's $file"

    # Command substitution strips trailing newlines. EnvironmentFile wants no
    # continuation, and the PEMs do not care about the final newline.
    value=$(<"$source")

    if [[ -z $value ]]; then
      die "$source is empty. That is never a valid secret -- if it should have" \
          "content then sops decrypted it to nothing, which means the file or" \
          "the decryption key is wrong."
    fi

    if [[ $format == raw ]]; then
      wanted="$value"
    else
      wanted="$env=$value"
    fi

    dir=$(jq -r '.dir // "/var/lib/incus-secrets"' <<<"$entry")
    path="$dir/$file"

    dir_mode=0711
    if [[ -n $group ]]; then
      # When the consumer group owns the directory, 0700 is both sufficient and
      # correct. Checked rather than assumed: an empty stat result must not be
      # read as "owned by the group" and reopen the directory.
      dir_owner=$(guest_read "$name" stat -c '%U' "$dir")
      if [[ $dir_owner == "$group" ]]; then
        dir_mode=0700
      else
        warn "$name:$file -- $dir is owned by '${dir_owner:-unknown}', not $group; falling back to 0711 so the consumer can still traverse it"
      fi
    fi

    # Compare bytes and ownership. A file with the right content but the wrong
    # mode is still broken, and the consumer fails while we report success.
    current_sum=$(guest_read "$name" sha256sum "$path" | cut -d' ' -f1)
    want_sum=$(printf '%s' "$wanted" | sha256sum | cut -d' ' -f1)
    cur_mode=$(guest_read "$name" stat -c '%a' "$path")
    cur_group=$(guest_read "$name" stat -c '%G' "$path")
    cur_dir_mode=$(guest_read "$name" stat -c '%a' "$dir")

    needs_write=0
    [[ -n $current_sum && $current_sum == "$want_sum" ]] || needs_write=1
    [[ $cur_mode == "${mode#0}" ]] || needs_write=1
    if [[ -n $group ]]; then
      [[ $cur_group == "$group" ]] || needs_write=1
    fi
    [[ -n $cur_dir_mode && $cur_dir_mode == "${dir_mode#0}" ]] || needs_write=1
    if [[ $needs_write == 0 ]]; then
      continue
    fi

    step "rendering $name:$file (mode $mode${group:+, group $group})"
    # mkdir/chmod the parent explicitly: an instance without a volume mounted at
    # this path has no directory, and a VM does not get one created for it.
    # chgrp before chmod, because chown-family calls can clear setgid bits.
    # printf, not a herestring: <<< appends a newline and would make a 43-byte
    # SECRET_KEY into a 44-byte file.
    cmd="export PATH=/run/current-system/sw/bin:\$PATH"
    cmd="$cmd && mkdir -p $dir && chmod $dir_mode $dir"
    cmd="$cmd && umask 077 && cat > $path"
    [[ -n $group ]] && cmd="$cmd && chgrp $group $path"
    cmd="$cmd && chmod $mode $path"
    printf '%s' "$wanted" | incus_run_stdin exec "$name" -- sh -c "$cmd"
    changed=1
  done

  [[ $changed == 1 ]] || return 0

  mapfile -t consumers < <(jq -r '.secretConsumers[]?' <<<"$spec")
  for unit in ${consumers[@]+"${consumers[@]}"}; do
    step "restarting $unit for the new secret"
    # reset-failed first: a consumer that lost its EnvironmentFile has already
    # tripped its own start rate limit, and restart would refuse.
    incus_run exec "$name" -- sh -c \
      "export PATH=/run/current-system/sw/bin:\$PATH; systemctl reset-failed '$unit'"
    # Unconditional restart: on a first deploy the unit never started, and
    # try-restart would leave it down.
    incus_run exec "$name" -- sh -c \
      "export PATH=/run/current-system/sw/bin:\$PATH; systemctl restart '$unit'"
  done

  # A restart is a request, not a result. Check that the consumer came up; a
  # unit that cannot read its file exits in milliseconds.
  for unit in ${consumers[@]+"${consumers[@]}"}; do
    state=""
    attempt=0
    while [[ $attempt -lt 10 ]]; do
      state=$(guest_read "$name" systemctl is-active "$unit")
      [[ $state == active ]] && break
      attempt=$((attempt + 1))
      sleep 1
    done
    [[ $state == active ]] && continue

    warn "$unit is '$state' after rendering $name's secrets; last lines of its log:"
    incus_run exec "$name" -- sh -c \
      "export PATH=/run/current-system/sw/bin:\$PATH; journalctl -u '$unit' --no-pager -n 12" \
      2>&1 | sed 's/^/      /' >&2 || true
    die "$unit did not come up after rendering $name's secrets (state: ${state:-unknown})." \
        "The instance is running but this consumer is not, so anything depending" \
        "on it -- for caddy, all hostnames -- is down."
  done
}

sync_incus_trust() {
  local name=$1 spec=$2 trust_name source want_norm fingerprint
  local -a stale

  trust_name=$(jq -r '.incusTrust.name // empty' <<<"$spec")
  [[ -n $trust_name ]] || return 0

  source=$(jq -r '.incusTrust.certificate // empty' <<<"$spec")
  [[ -n $source ]] || die "$name declares incusTrust but names no certificate"
  assert_secret_readable "$source" "$name's client certificate"

  want_norm=$(tr -d '[:space:]' <"$source")

  # Trusted already, under any name. A certificate added by hand must not get a
  # second, redundant entry.
  if incus config trust list --format json \
       | jq -e --arg c "$want_norm" 'any(.certificate | gsub("\\s"; "") == $c)' \
       >/dev/null; then
    return 0
  fi

  [[ $EUID -eq 0 ]] || die "$name declares incusTrust but incus-secrets is not root"

  # A same-named entry holding something else means the certificate rotated.
  # Remove by fingerprint, not name: `trust remove <name>` finds nothing.
  mapfile -t stale < <(incus config trust list --format json \
    | jq -r --arg n "$trust_name" '.[] | select(.name == $n) | .fingerprint')

  for fingerprint in ${stale[@]+"${stale[@]}"}; do
    warn "trust entry '$trust_name' holds a different certificate (${fingerprint:0:12}); replacing it"
    incus_global config trust remove "$fingerprint"
  done

  step "trusting $name's client certificate as '$trust_name'"
  incus_global config trust add-certificate --name "$trust_name" \
    --description "$name: authenticates to the Incus API from its Caddy vhost" \
    "$source"
}

while IFS= read -r name; do
  spec=$(jq -c --arg n "$name" '.instances[$n]' "$SPECS_FILE")
  PROJECT=$(jq -r --arg n "$name" '.projects[$n] // ""' "$SPECS_FILE")

  if ! instance=$(incus query "/1.0/instances/$name$(project_qs)" 2>/dev/null); then
    warn "$name does not exist${PROJECT:+ in project $PROJECT}; skipping"
    continue
  fi

  status=$(jq -r '.status // empty' <<<"$instance")
  case $status in
    Running|Frozen) ;;
    *)
      log "$name is ${status:-unknown}; skipping"
      continue
      ;;
  esac

  render_secrets "$name" "$spec"
  sync_incus_trust "$name" "$spec"
done < <(jq -r '.instances | keys[]' "$SPECS_FILE")
