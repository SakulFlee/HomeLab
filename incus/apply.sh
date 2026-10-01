#!/usr/bin/env bash
#
# incus/apply.sh -- build a NixOS container image from the flake and make the
# running Incus instance match it.
#
# This is safe to run on every change, which is what lets the host run it from
# a systemd.paths unit on every edit. It only does work when something differs:
#
#   * Nix builds are content-addressed and make-squashfs.nix pins every
#     timestamp to 1970-01-01, so rebuilding an unchanged configuration gives a
#     byte-identical image and therefore an identical Incus fingerprint.
#   * An instance is only recreated when its volatile.base_image fingerprint no
#     longer matches the image just imported. That is the exact test, and it is
#     why a dirty git tree does not cause pointless downtime: a dirty tree can
#     change the build inputs without changing the bytes that come out.
#   * Devices and limits are diffed against what the instance already has, so
#     changing a memory limit never touches the root disk.
#
# Usage:
#   incus/apply.sh [--check] [--no-start] <instance>...
#   incus/apply.sh --all
#
# Options:
#   --check     Build the image and report what has drifted. Read-only: no
#               image import, no instance create, no start.
#   --no-start  Leave the instance stopped, whatever its spec's autostart says.
#               For a manual run, not for the automatic ones.
#   --all       Every instance in the flake.
#
# Environment:
#   INCUS_REPO_DIR      checkout root          (default /etc/nixos)
#   INCUS_FLAKE_DIR     flake to build from    (default $INCUS_REPO_DIR/nixos)
#   INCUS_IMAGE_PREFIX  image alias prefix     (default homelab)
#
# Run state is declarative: an instance ends up however `autostart` in its spec
# says. To keep one down across a redeploy, set `autostart = false` in its
# incus.nix -- which is itself a change, so applying it terminates rather than
# looping. See the comment in apply_instance for why this replaced an earlier
# "preserve prior run state" rule.
#
# Never deletes an image. Old ones are left for Incus's own GC.

set -Eeuo pipefail

# systemd services get a deliberately minimal PATH, and sudo's secure_path is
# not guaranteed to include the current system. Pin it.
export PATH="/run/current-system/sw/bin:$PATH"

REPO_DIR="${INCUS_REPO_DIR:-/etc/nixos}"
FLAKE_DIR="${INCUS_FLAKE_DIR:-$REPO_DIR/nixos}"
IMAGE_PREFIX="${INCUS_IMAGE_PREFIX:-homelab}"

CHECK_ONLY=0
NO_START=0
ALL=0
declare -a REQUESTED=()

# Set per instance so log lines stay attributable when --all is running several
# in one journal.
TAG="apply"

# All logging goes to stderr on purpose. build_artifacts' two paths are returned
# on stdout and captured with mapfile, and a "== building image" on stdout would
# be read as the first path -- which is exactly the bug this comment exists to
# prevent. Keeping stdout data-only means that class of mistake cannot recur.
log()  { printf '%-9s %s\n' "$TAG" "$*" >&2; }
step() { printf '%-9s == %s\n' "$TAG" "$*" >&2; }
warn() { printf '%-9s WARN: %s\n' "$TAG" "$*" >&2; }
die()  { printf '%-9s ERROR: %s\n' "$TAG" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# The name ends up in an image alias and in shell arguments. Refuse anything
# outside the conservative set rather than trying to escape it.
# --------------------------------------------------------------------------
valid_name() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

# --------------------------------------------------------------------------
# Every mutating Incus call goes through this.
#
# Two reasons, both learned the hard way.
#
# stdin: the Incus client reads stdin when stdin is not a TTY and sends it as
# the HTTP request body. A loop that feeds jq's output in with `< <(...)`
# therefore hands the *next* line of JSON to the server as a body, and the
# reply is
#
#   Error: yaml: construct errors: line 1: field pool not found in
#   type api.StorageVolumePut
#
# which mentions neither the command nor the cause. It only bites at two or
# more iterations -- with one volume, the earlier `show` consumes the only line
# and `create` sees EOF -- which is why caddy passed and forgejo did not.
# Redirecting from /dev/null fixes it at the source rather than per call site.
#
# argv: that error text did not identify the offending command once in five CLI
# surprises, so the exact invocation is logged before it runs.
incus_run() {
  log "incus $(printf '%q ' "$@")"
  incus "$@" </dev/null
}

# --------------------------------------------------------------------------
# Nix
# --------------------------------------------------------------------------
# One name per line, not the raw JSON. `nix eval --json --apply
# builtins.attrNames` emits ["caddy","forgejo"] as a *single line*, so a plain
# mapfile over it produces one element holding the whole array -- and
# `--all` then fails name validation on the string '["caddy","forgejo"]'.
flake_instances() {
  nix eval --json "$FLAKE_DIR#incusInstances" --apply builtins.attrNames 2>/dev/null \
    | jq -r '.[]' \
    || die "cannot read incusInstances from $FLAKE_DIR"
}

instance_spec() {
  local name=$1
  nix eval --json "$FLAKE_DIR#incusInstances.$name" 2>/dev/null \
    || die "no instance '$name' -- is it in nixos/incus-instances.nix?"
}

# Warn when the *tracked* content differs from HEAD, because that is the only
# thing that can make this image differ from a rebuild of the committed tree.
#
# Untracked files are deliberately excluded. A git+file:// flake is built from
# the git tree, so an untracked file cannot reach the image at all -- Nix says so
# itself and refuses to evaluate, e.g.
#   To make it visible to Nix, run: git -C ... add -N "nixos/foo.nix"
# Including them here produced a permanent false alarm: a stray 79-byte file
# named "sudo" in the flake directory (a shell redirect that landed there during
# some earlier debugging) kept every single run reporting a dirty tree.
#
# What was actually built is recorded on the image as user.flake-rev, so the
# commit is recoverable after the fact without needing this at all.
warn_dirty_tree() {
  local dirty
  dirty=$(git -C "$REPO_DIR" status --porcelain --untracked-files=no 2>/dev/null || true)
  if [[ -n $dirty ]]; then
    warn "$REPO_DIR has uncommitted changes to tracked files; this image is built"
    warn "from the working tree, not from $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')."
  fi
}

# Echo the two artefacts `incus image import` needs, one per line.
#
# Both are required. The rootfs alone would give the container a nix database
# that knows about none of its own store paths; the metadata tarball carries
# nix-path-registration, which is what registers them on first boot. Dropping it
# is the classic way to produce an image that boots and then cannot run nix.
build_artifacts() {
  local name=$1 sq_out md_out
  local -a roots metadata_files

  step "building image"
  sq_out=$(nix build "$FLAKE_DIR#nixosConfigurations.$name.config.system.build.squashfs" \
    --no-link --print-out-paths)
  md_out=$(nix build "$FLAKE_DIR#nixosConfigurations.$name.config.system.build.metadata" \
    --no-link --print-out-paths)

  shopt -s nullglob
  # .img is what older nixpkgs emitted, .squashfs what current emits.
  roots=("$sq_out"/*.squashfs "$sq_out"/*.img)
  metadata_files=("$md_out"/tarball/*.tar.xz "$md_out"/*.tar.xz)
  shopt -u nullglob

  [[ ${#roots[@]} -eq 1 ]] || die "expected one rootfs image in $sq_out, found ${#roots[@]}"
  [[ ${#metadata_files[@]} -eq 1 ]] \
    || die "expected one metadata tarball in $md_out, found ${#metadata_files[@]}"

  printf '%s\n%s\n' "${roots[0]}" "${metadata_files[0]}"
}

# --------------------------------------------------------------------------
# Incus
# --------------------------------------------------------------------------

# The fingerprint an alias currently names, or empty. `incus query` does NOT
# resolve image aliases (verified: /1.0/images/<alias> 404s), so go through the
# list filter.
image_fingerprint() {
  incus image list "$1" --format json 2>/dev/null \
    | jq -r --arg a "$1" 'map(select(any(.aliases[]?; .name == $a))) | .[0].fingerprint // empty'
}

# The store path of the squashfs the image at an alias was built from. This is
# how we recognise "already have this exact image" without importing it.
image_build_source() {
  incus image get-property "$1" user.build-source 2>/dev/null || true
}

# Any image in the pool built from this exact squashfs. Used to recover from an
# alias that names a stale image when the wanted content is already present.
image_with_build_source() {
  incus image list --format json 2>/dev/null \
    | jq -r --arg s "$1" '.[] | select(.properties["user.build-source"] == $s) | .fingerprint' \
    | head -1
}

# Make the alias name an image. Import attaches it for new content, but not when
# it short-circuits, so this is needed on the recovery path.
point_alias_at() {
  local alias=$1 fingerprint=$2
  local current
  current=$(image_fingerprint "$alias" || true)
  if [[ $current != "$fingerprint" ]]; then
    incus_run image alias create "$alias" "$fingerprint"
  fi
}

# Echo the fingerprint the instance should be based on.
import_image() {
  local rootfs=$1 metadata_tarball=$2 alias=$3 rev=$4
  local output fingerprint

  # Fast path, and the one that runs on every no-op redeploy: the alias already
  # names an image built from exactly this output, so there is nothing to do.
  # No import, no Incus mutation, nothing that can go quietly wrong.
  if [[ -n $(image_fingerprint "$alias" || true) ]] \
     && [[ $(image_build_source "$alias") == "$rootfs" ]]; then
    step "image unchanged, Incus already has this exact build"
  else
    # Argument order is metadata first, rootfs second:
    #   incus image import (<tarball>|<directory>|<URL>) [<rootfs tarball>]
    # The name of the first argument is generic because it is the *metadata*
    # tarball. Handing them over the other way round gets
    #   Error: Metadata tarball is missing metadata.yaml
    # because Incus is reading the squashfs as the metadata. The old LXD-era
    # examples online have this backwards.
    #
    # Deliberately no --reuse: it deletes an existing image that already carries
    # the alias.
    if output=$(incus image import "$metadata_tarball" "$rootfs" --alias "$alias" 2>&1); then
      :
    elif grep -qi "already exists" <<<"$output"; then
      # This is a real failure, not a polite no-op:
      #   Error: Image with same fingerprint already exists
      # and the exit status is non-zero. Treating it as success is how this went
      # wrong once already: Incus does NOT attach the alias on this path, so the
      # alias keeps naming whatever it named before. Reading the fingerprint
      # back from the alias then compares against that stale image and declares
      # the instance up to date while it is running something else entirely.
      #
      # So: find the image that actually holds this build, and say so out loud
      # if there is not one.
      step "content already in the pool, re-pointing $alias at it"
      fingerprint=$(image_with_build_source "$rootfs")
      if [[ -z $fingerprint ]]; then
        die "this build is already in the pool under no alias and carries no" \
            "user.build-source, so it cannot be identified. Find it with" \
            "'incus image list' and either give it an alias or delete it, then retry."
      fi
      point_alias_at "$alias" "$fingerprint"
    else
      die "image import failed:"$'\n'"$output"
    fi
  fi

  fingerprint=$(image_fingerprint "$alias")
  [[ -n $fingerprint ]] || die "$alias resolved to no fingerprint after import"

  # Provenance, recorded on the image the alias provably names.
  #
  # Safe to write *now* and not before, because by this point the alias is known
  # to name the image we built on all three paths: a successful import attached
  # it, the fast path matched on this very value, and the recovery path moved it
  # with point_alias_at. Writing it earlier -- before the alias was resolved --
  # is how a stale image ended up carrying someone else's build path, and that
  # lie then poisoned every later comparison.
  if [[ $(image_build_source "$alias") != "$rootfs" ]]; then
    incus_run image set-property "$alias" "user.build-source=$rootfs"
  fi

  # Round-trip check. Every later comparison reads the build path back from the
  # alias, so the write above has to have landed on the image the alias names and
  # stayed there. Cheap, and the failure mode it guards is silent.
  if [[ $(image_build_source "$alias") != "$rootfs" ]]; then
    die "$alias names image $fingerprint, whose build-source is" \
        "'$(image_build_source "$alias")' rather than '$rootfs'." \
        "Refusing to compare fingerprints against the wrong image."
  fi

  # flake-rev is informational and safe to refresh every run, but diffed anyway
  # so a no-op redeploy performs no writes at all.
  if [[ -n $rev ]] && [[ $(incus image get-property "$alias" user.flake-rev 2>/dev/null || true) != "$rev" ]]; then
    incus_run image set-property "$alias" "user.flake-rev=$rev"
  fi

  printf '%s\n' "$fingerprint"
}

instance_exists() {
  incus info "$1" >/dev/null 2>&1
}

instance_field() {
  incus query "/1.0/instances/$1" | jq -r "$2"
}

ensure_volumes() {
  local name=$1 spec=$2 volume pool volume_name description current
  local -a volumes

  # mapfile then for, never `while read ... done < <(jq)`. The while-read form
  # leaves jq's pipe on stdin for every command in the body, which is how the
  # Incus client ended up POSTing a line of JSON as a request body. mapfile
  # drains the pipe before the loop starts, so the body inherits the script's own
  # stdin. See incus_run.
  mapfile -t volumes < <(jq -c '.volumes[]?' <<<"$spec")

  for volume in ${volumes[@]+"${volumes[@]}"}; do
    pool=$(jq -r '.pool' <<<"$volume")
    volume_name=$(jq -r '.name' <<<"$volume")
    description=$(jq -r '.description // ""' <<<"$volume")

    # Pool and volume are separate positional arguments, not "pool/volume":
    #   incus storage volume show [<remote>:]<pool> [<type>/]<volume>
    # Passing one combined string parses as pool=backup with the volume
    # missing, so the command fails even when the volume is there -- and the
    # code below then tries to create it and dies with
    #   Error: Volume by that name already exists
    # on every run after the first. Verified against `incus storage volume
    # show --help` rather than guessed.
    if ! incus storage volume show "$pool" "$volume_name" >/dev/null 2>&1; then
      step "creating volume $pool/$volume_name"
      incus_run storage volume create "$pool" "$volume_name"
    fi

    # Description is reconciled, not just set on creation. Two reasons: a
    # volume predating this code keeps whatever it had, and `incus storage
    # volume list` is where someone reads "never file-back-up, pg_dump only"
    # next to the PGDATA volume -- which is the whole point of writing it.
    #
    # NOT `incus storage volume set <pool> <volume> description=...`.
    # description is a top-level API field, not a config key, so the CLI
    # rejects it with
    #   Error: Invalid option for volume "..." option "description"
    # The API path needs the volume type segment; the bare form 404s.
    if [[ -n $description ]]; then
      # Read via the API, not `incus storage volume show`: that prints YAML,
      # and piping it to jq dies with
      #   jq: parse error: Invalid numeric literal at line 1, column 7
      current=$(incus query "/1.0/storage-pools/$pool/volumes/custom/$volume_name" \
        | jq -r '.description // ""')
      if [[ $current != "$description" ]]; then
        incus_run query -X PATCH \
          -d "$(jq -cn --arg d "$description" '{description: $d}')" \
          "/1.0/storage-pools/$pool/volumes/custom/$volume_name"
      fi
    fi
  done
}

# Incus sets limits.instances itself as a guard rail, and btrfs volumes can
# carry limits.disk.priority of their own. Reconcile only the resource limits
# we are willing to own and leave the rest alone.
MANAGED_LIMITS=(memory cpu processes disk network priority)

apply_limits() {
  local name=$1 spec=$2 key value current
  for key in "${MANAGED_LIMITS[@]}"; do
    value=$(jq -r --arg k "$key" '.limits[$k] // empty' <<<"$spec")
    current=$(instance_field "$name" ".config[\"limits.$key\"] // empty")

    if [[ -n $value ]]; then
      if [[ $value != "$current" ]]; then
        step "setting limits.$key = $value"
        # key=value in one argument. The two-argument form still works but
        # prints "the <key> <value> syntax is deprecated" on every call.
        incus_run config set "$name" "limits.$key=$value"
      fi
    elif [[ -n $current ]]; then
      step "clearing limits.$key"
      incus_run config unset "$name" "limits.$key"
    fi
  done
}

# Render the host's secrets into the instance as EnvironmentFiles.
#
# This is the whole of an instance's access to a secret, and it is deliberately
# not a key. The alternative -- mounting the host's SSH identity key and running
# sops-nix inside the container -- works and grants a root process in there the
# ability to decrypt every value in the host's secrets.yaml, not just the one
# the instance was given. Handing over a rendered value means the instance has
# no decryption capability at all.
#
# The value is piped in on stdin and never becomes a command-line argument, so
# it does not land in the process table.
#
# Diffed against what is already there, so a settled redeploy writes nothing --
# a secret file is not something to churn.
render_secrets() {
  local name=$1 spec=$2 entry file env source value wanted current unit
  local changed=0
  local -a entries consumers

  mapfile -t entries < <(jq -c '.renderedSecrets[]?' <<<"$spec")
  [[ ${#entries[@]} -eq 0 ]] && return 0

  [[ $EUID -eq 0 ]] || die "$name declares renderedSecrets but apply.sh is not root"

  for entry in "${entries[@]}"; do
    file=$(jq -r '.file' <<<"$entry")
    env=$(jq -r '.env' <<<"$entry")
    source=$(jq -r '.source' <<<"$entry")

    if [[ ! -r $source ]]; then
      # Fail loudly rather than writing an empty file: an empty CF_API_TOKEN
      # makes Caddy refuse to start, and "environment file missing" is a much
      # better error than "API token '' appears invalid".
      die "$source is not readable, so $name's $file cannot be rendered." \
          "It is materialised by the host's sops.secrets on activation -- is the" \
          "host missing a nixos-rebuild?"
    fi

    # Command substitution strips the trailing newline, which is what
    # EnvironmentFile wants anyway (one KEY=value per line, no continuation).
    value=$(<"$source")
    wanted="$env=$value"

    current=$(incus exec "$name" -- cat "/var/lib/incus-secrets/$file" 2>/dev/null || true)
    if [[ $current == "$wanted" ]]; then
      continue
    fi

    step "rendering $name:$file"
    incus_run exec "$name" -- sh -c \
      "umask 077 && cat > /var/lib/incus-secrets/$file && chmod 0400 /var/lib/incus-secrets/$file" \
      <<<"$wanted"
    changed=1
  done

  # Only when something actually changed, and only for the units that consume it.
  #
  # The restart is not optional. A unit whose EnvironmentFile is missing fails
  # to start, so on a first deploy caddy.service is down at this point with the
  # file on disk but unread; `try-restart` would be a no-op there, so this is an
  # unconditional `restart`, which starts a stopped unit as a side effect.
  [[ $changed == 1 ]] || return 0
  mapfile -t consumers < <(jq -r '.secretConsumers[]?' <<<"$spec")
  for unit in ${consumers[@]+"${consumers[@]}"}; do
    step "restarting $unit for the new secret"
    incus_run exec "$name" -- systemctl restart "$unit"
  done
}

# True when every key we want is present on the device with the same value.
# Subset rather than equality: Incus may add defaults we do not care about, and
# reapplying a device on every run is worse than tolerating an extra key.
device_matches() {
  local current=$1 want=$2
  jq -e --argjson cur "$current" --argjson want "$want" '
    all($want | to_entries[];
        (($cur[.key] // null) | tostring) == (.value | tostring))
  ' <<<'null' >/dev/null 2>&1
}

sync_devices() {
  local name=$1 spec=$2
  local desired current key device
  local -a have want

  desired=$(jq -c '.devices // {}' <<<"$spec")
  current=$(incus query "/1.0/instances/$name" | jq -c '.devices // {}')

  # mapfile then for, never `while read ... done < <(jq)`: see incus_run for
  # what a pipe on stdin does to the Incus client.
  mapfile -t have < <(jq -r 'keys[]' <<<"$current")
  mapfile -t want < <(jq -r 'keys[]' <<<"$desired")

  # Drop devices we previously managed that are no longer declared. root is
  # never in the spec -- it comes from the default profile -- and removing it
  # would destroy the instance's root disk.
  for key in ${have[@]+"${have[@]}"}; do
    if [[ $key == root ]]; then
      continue
    fi
    if ! jq -e --arg k "$key" 'has($k)' <<<"$desired" >/dev/null; then
      step "removing device $key"
      incus_run config device remove "$name" "$key"
    fi
  done

  # Add or update the rest. remove-then-add rather than a key-by-key diff:
  # changing a device's type is not possible in place, so a full replace is the
  # one path that always works.
  for key in ${want[@]+"${want[@]}"}; do
    device=$(jq -c --arg k "$key" '.[$k]' <<<"$desired")
    if device_matches "$(jq -c --arg k "$key" '.[$k] // {}' <<<"$current")" "$device"; then
      continue
    fi
    step "applying device $key"
    incus config device remove "$name" "$key" >/dev/null 2>&1 || true
    # The device's type is a *positional* argument, not one of the k=v
    # properties:
    #
    #   incus config device add <instance> <key> <type> [<key>=<value>...]
    #
    # Passing type=disk as a property instead gives the CLI a type of
    # "disk=disk=..." and it replies
    #   Error: Invalid devices: ... Unsupported device type
    # Unquoted on purpose: one argv entry per k=v, which is how the CLI wants
    # them. Quoting would pass "pool=backup source=x" as a single key.
    # shellcheck disable=SC2046
    incus_run config device add "$name" "$key" \
      "$(jq -r '.type' <<<"$device")" \
      $(jq -r 'to_entries[] | select(.key != "type") | "\(.key)=\(.value)"' <<<"$device")
  done
}

# user.description rather than the top-level description field: setting that
# needs an API PATCH, and a PATCH that is subtly wrong would rewrite the
# instance's devices. Not worth the risk for a label.
set_description() {
  local name=$1 spec=$2 description current
  description=$(jq -r '.description // empty' <<<"$spec")
  if [[ -n $description ]]; then
    current=$(instance_field "$name" '.config["user.description"] // empty')
    if [[ $current != "$description" ]]; then
      incus_run config set "$name" "user.description=$description"
    fi
  fi
}

# Wait for the instance to be Running *and*, if it has a NIC, to actually have an
# address. Incus reports Running as soon as the container is started, which is
# well before systemd-networkd has configured eth0 -- so returning there made
# apply print "ok -- Running" with an empty address, which reads like a
# networking failure and is not one.
wait_ready() {
  local name=$1 want_ip=$2 attempt=0 status address

  while [[ $attempt -lt 60 ]]; do
    status=$(instance_field "$name" '.status')
    case $status in
      Stopped|Error) return 0 ;;
    esac
    if [[ $status == Running || $status == Frozen ]]; then
      if [[ $want_ip == no ]]; then
        return 0
      fi
      address=$(instance_address "$name")
      if [[ -n $address ]]; then
        return 0
      fi
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  warn "$name had no address on eth0 after 60s (status: $status)"
}

# The inet addresses on eth0 only. Not every interface: .state.network also
# carries lo, whose inet address is 127.0.0.1 and would otherwise be reported.
instance_address() {
  incus list "$1" --format json \
    | jq -r '.[0].state.network.eth0.addresses[]? | select(.family == "inet") | .address' \
    | paste -sd, -
}

# "vrvf2p9...-nixos-lxc-image-x86_64-linux" from a store path. The hash is the
# part that changes; the bare filename is the same for every instance.
store_name() {
  local dir=${1%/*}
  printf '%s' "${dir##*/}"
}

# --------------------------------------------------------------------------
# --check: report drift without touching anything
# --------------------------------------------------------------------------
report_drift() {
  local name=$1 build_path=$2 spec=$3 alias
  alias="$IMAGE_PREFIX/$name"
  log "no instance named $name -- would create it from $alias"
  log "  image build output: $(store_name "$build_path")"
  log "  volumes: $(jq -r '[.volumes[]? | "\(.pool)/\(.name)"] | join(", ")' <<<"$spec")"
  log "  devices: $(jq -r '[.devices | keys[]] | join(", ")' <<<"$spec")"
}

report_existing_drift() {
  local name=$1 spec=$2 build_path=$3 old_fingerprint=$4
  local key value current want_dev cur_dev device alias recorded
  local -a want_keys

  alias="$IMAGE_PREFIX/$name"
  recorded=$(incus image get-property "$alias" user.build-source 2>/dev/null || true)

  log "instance base image ${old_fingerprint:0:12} ($(instance_field "$name" '.status'))"
  if [[ -z $recorded ]]; then
    log "  no image at alias $alias yet"
  elif [[ $recorded == "$build_path" ]]; then
    log "  build inputs unchanged since the last deploy"
  else
    log "  build inputs changed:"
    log "    have $(store_name "$recorded")"
    log "    want $(store_name "$build_path")"
  fi
  log "  whether that means a recreate is decided by image fingerprint at apply"
  log "  time; a changed build path does not necessarily mean changed bytes"

  for key in "${MANAGED_LIMITS[@]}"; do
    value=$(jq -r --arg k "$key" '.limits[$k] // empty' <<<"$spec")
    current=$(instance_field "$name" ".config[\"limits.$key\"] // empty")
    if [[ $value != "$current" ]]; then
      log "  limits.$key: have '${current:-unset}' want '${value:-unset}'"
    fi
  done

  cur_dev=$(incus query "/1.0/instances/$name" | jq -c '.devices // {}')
  want_dev=$(jq -c '.devices // {}' <<<"$spec")
  # mapfile then for, for the same reason as sync_devices.
  mapfile -t want_keys < <(jq -r 'keys[]' <<<"$want_dev")
  for key in ${want_keys[@]+"${want_keys[@]}"}; do
    device=$(jq -c --arg k "$key" '.[$k]' <<<"$want_dev")
    if ! device_matches "$(jq -c --arg k "$key" '.[$k] // {}' <<<"$cur_dev")" "$device"; then
      log "  device $key: have $(jq -c --arg k "$key" '.[$k] // {}' <<<"$cur_dev") want $device"
    fi
  done
}

# --------------------------------------------------------------------------
# The reconcile
# --------------------------------------------------------------------------
apply_instance() {
  local name=$1
  local spec alias fingerprint rev build_output
  local existed=0 want_running=1 old_fingerprint=""
  local rootfs metadata
  local -a artifacts

  TAG="$name"
  spec=$(instance_spec "$name")
  alias="$IMAGE_PREFIX/$name"
  rev=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)

  if instance_exists "$name"; then
    existed=1
    old_fingerprint=$(instance_field "$name" '.config["volatile.base_image"] // ""')
  fi

  # Run state is declarative: the instance ends up however `autostart` in its
  # spec says, full stop. No "preserve whatever it was doing" heuristic.
  #
  # An earlier version tried to preserve prior run state, and it had two
  # failure modes that both reported success while being wrong:
  #
  #   * An apply that died between `incus create` and `incus start` left the
  #     instance Stopped, and the next apply dutifully preserved that -- so a
  #     half-finished deploy stayed half-finished, printing "ok -- Stopped".
  #   * Telling a deliberate stop from a never-started instance needed
  #     volatile.last_state.power, which records STOPPED after a stop, not
  #     RUNNING. So it could not tell them apart and restarted instances the
  #     user had deliberately stopped.
  #
  # One rule is easier to reason about than a heuristic. To keep an instance
  # down across a redeploy, set `autostart = false` in its incus.nix -- which is
  # itself a change, so applying it terminates rather than looping.
  want_running=1
  if [[ $NO_START == 1 ]]; then
    want_running=0
  fi
  # NOT `jq -r '.autostart // true'`. In jq, // is the alternative operator and
  # it treats false as empty, so `false // true` yields *true* -- which silently
  # inverts the one setting that decides whether the instance comes up. Spell it
  # out: only an explicit false means false.
  if [[ $(jq -r 'if has("autostart") then (.autostart | tostring) else "true" end' <<<"$spec") == false ]]; then
    want_running=0
  fi

  # Command substitution, not `mapfile < <(...)`, and checked explicitly. A
  # process substitution runs in a subshell whose exit status the parent never
  # sees, so a `die` inside build_artifacts would print its message and then be
  # swallowed -- the script would carry on with an empty artifact list. With a
  # command substitution the non-zero status lands here, where it is fatal.
  if ! build_output=$(build_artifacts "$name"); then
    die "could not build the $name image (see the build output above)"
  fi
  mapfile -t artifacts <<<"$build_output"
  [[ ${#artifacts[@]} -eq 2 ]] || die "expected two build artifacts, got ${#artifacts[@]}"
  rootfs=${artifacts[0]}
  metadata=${artifacts[1]}

  if [[ $CHECK_ONLY == 1 ]]; then
    if [[ $existed == 1 ]]; then
      report_existing_drift "$name" "$spec" "$rootfs" "$old_fingerprint"
    else
      report_drift "$name" "$rootfs" "$spec"
    fi
    return 0
  fi

  fingerprint=$(import_image "$rootfs" "$metadata" "$alias" "$rev")
  step "image ${fingerprint:0:12}"

  ensure_volumes "$name" "$spec"

  if [[ $existed == 1 && $old_fingerprint == "$fingerprint" ]]; then
    step "already running this image, not recreating"
  elif [[ $existed == 1 ]]; then
    step "image changed (${old_fingerprint:0:12} -> ${fingerprint:0:12}), recreating"
    warn "$name goes down while its root disk is replaced; volumes are untouched"
    incus_run delete "$name" --force
    existed=0
  fi

  if [[ $existed == 0 ]]; then
    step "creating $name"
    incus_run create "$fingerprint" "$name" -p default
  fi

  set_description "$name" "$spec"
  apply_limits "$name" "$spec"
  sync_devices "$name" "$spec"

  if [[ $want_running == 1 ]]; then
    if [[ $(instance_field "$name" '.status') != Running ]]; then
      step "starting"
      incus_run start "$name"
      # A NIC in the spec means an address is expected; without one there is
      # nothing to wait for.
      want_ip=no
      jq -e '.devices | to_entries | any(.value.type == "nic")' <<<"$spec" >/dev/null && want_ip=yes
      wait_ready "$name" "$want_ip"
    fi
  elif [[ $(instance_field "$name" '.status') == Running ]]; then
    step "stopping (autostart off, or --no-start)"
    incus_run stop "$name"
  fi

  # AFTER the start, not before. render_secrets works through `incus exec`,
  # which needs a running instance -- so calling it earlier meant the first
  # deploy of any instance with renderedSecrets died at this line and left the
  # instance stopped with the image already applied. On a redeploy where the
  # instance was already running it happened to work, which is why it looked
  # fine until the first fresh create.
  #
  # A consumer unit may be failed at this point, because its EnvironmentFile is
  # the thing that has not been written yet. render_secrets restarts it.
  if [[ $want_running == 1 ]]; then
    render_secrets "$name" "$spec"
  fi

  local status addresses
  status=$(instance_field "$name" '.status')
  addresses=$(instance_address "$name")
  log "ok -- $status${addresses:+ ($addresses)}"
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------
usage() {
  # The comment block at the top is the help text. Print the part that documents
  # usage rather than trying to keep a second copy in sync by hand.
  sed -n '/^# Usage:/,/^set -/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --check)    CHECK_ONLY=1 ;;
    --no-start) NO_START=1 ;;
    --all)      ALL=1 ;;
    -h|--help)  usage; exit 0 ;;
    --)         shift; break ;;
    -*)         die "unknown option '$1' (try --help)" ;;
    *)          REQUESTED+=("$1") ;;
  esac
  shift
done
REQUESTED+=("$@")

if [[ $ALL == 1 ]]; then
  mapfile -t REQUESTED < <(flake_instances)
fi
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  die "no instance given. Use --all, or name one. Known: $(flake_instances | paste -sd' ' -)"
fi
for name in "${REQUESTED[@]}"; do
  valid_name "$name" || die "'$name' is not a valid instance name (want [a-z0-9-])"
done

[[ -d $FLAKE_DIR ]] || die "no flake at $FLAKE_DIR (set INCUS_FLAKE_DIR)"
command -v nix >/dev/null || die "nix not in PATH"
command -v jq >/dev/null || die "jq not in PATH"
if [[ $CHECK_ONLY != 1 ]]; then
  command -v incus >/dev/null || die "incus not in PATH"
  [[ $EUID -eq 0 ]] || warn "not root: image import and instance changes will likely be refused"
fi

warn_dirty_tree

if [[ $CHECK_ONLY == 1 ]]; then
  log "--check: building images, changing nothing"
else
  log "reconciling ${#REQUESTED[@]} instance(s) from $FLAKE_DIR"
fi

for name in "${REQUESTED[@]}"; do
  apply_instance "$name"
done

TAG="apply"
log "done"
