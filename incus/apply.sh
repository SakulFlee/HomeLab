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
#   --project   Incus project the instances live in (default: default).
#
#               Needed because Incus resolves a bare instance name against
#               the *current* project, and the current project is whichever was
#               last selected. An instance in the forgejo project that is
#               addressed as plain `forgejo` is not found at all: `incus info`
#               fails, `storage volume show` reports the volume missing, and the
#               run either dies or recreates a duplicate in the wrong project.
#
#               Storage volumes are project-scoped, which is the second half of
#               why this matters. Measured, not assumed: `incus storage volume
#               list backup --project forgejo` returns nothing while the default
#               project sees caddy-data and forgejo-repositories. So moving an
#               instance between projects is not a rename -- it is new, empty
#               volumes, and they must exist in the target project *before* any
#               data is restored into them, or the restore lands in a volume
#               nothing is reading from.
#
#               Networks are NOT project-scoped in Incus 7: `incus network list
#               --project forgejo` lists incusbr0 alongside the rest, so no
#               features.networks opt-in is needed for the bridge to stay usable
#               from another project.
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
# Never deletes an image. That is the right rule inside a reconcile -- a half
# applied deploy that also dropped a rollback target would be two problems at once
# -- but it used to end "...left for Incus's own GC", and there is no Incus GC.
# Measured: 20 unaliased images of ours sat in the `default` project and 14 in
# `forgejo`, 16 of them from a nixpkgs pin weeks old, all with
# `used_by: null`, and nothing had ever been pruned. incus/incus-image-gc.sh is
# the other half of this contract and runs it weekly.

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
PROJECT=""
PROJECT_OVERRIDE=""
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

# Exact, whole-line membership. `[[ " $list " == *" $item "* ]]` would be
# shorter and is wrong here: these are space-separated tuples, so "tcp 80" is a
# substring of "tcp 8080" and the forward would be considered already correct.
in_list() {
  local needle=$1 item
  shift
  for item in ${1+"$@"}; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
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
#
# --project is injected in incus_run rather than at each of the ~36 call sites.
# It is a global flag on the incus CLI, valid for every subcommand from `info` to
# `network forward port add`, and the alternative -- addressing an instance as
# `project:name` -- is not accepted by `storage volume` or `network forward`,
# which are the two that most need it. One insertion point, and every call site
# that goes through incus_run inherits it.
#
# It was previously `project_args()`, returning a NUL-delimited flag pair. That
# function was never called by anything: incus_run builds its own array. Deleted
# rather than left as a second, subtly different way to spell the same thing.
#
# ---------------------------------------------------------------------------
# The URL form, for the calls that CANNOT use incus_run.
# ---------------------------------------------------------------------------
# `incus query` takes a raw API path and does not translate --project onto it,
# so those call sites need ?project= on the URL instead. Every one of them missed
# it at first and the failures were silent rather than loud:
#
#   incus query /1.0/instances/forgejo              -> 404, .devices reads {}
#       so sync_devices saw no devices and fought the spec forever.
#   incus query /1.0/storage-pools/persistent/volumes/custom/forgejo-postgres
#                                                    -> 404, description never set.
#
# Both are worse than an outright failure: they read as "nothing is configured"
# rather than "I looked in the wrong place". So the query string is built here,
# once, and callers interpolate it.
#
# Empty for the default project, which keeps those URLs byte-identical to what
# they were before projects existed.
project_qs() {
  [[ -n $PROJECT ]] && printf '?project=%s' "$PROJECT" || printf ''
}

# --------------------------------------------------------------------------
# Projects
# --------------------------------------------------------------------------
# incusInstances and incusInstanceProjects are cached for the run, and this is
# the third of that family. Evaluating the flake is the expensive part of this
# script, and the reconcile timer runs --all every fifteen minutes across three
# instances spanning two projects, so the map is fetched once and reused rather
# than per call. Empty means "not fetched yet", which is distinguishable from
# "{}" ("fetched, and there are none") because the eval can fail outright on a
# broken flake -- that must not read as "this project is unmanaged".
PROJECTS_JSON=""
projects_json() {
  if [[ -z $PROJECTS_JSON ]]; then
    PROJECTS_JSON=$(nix eval --json "$FLAKE_DIR#incusProjects" 2>/dev/null || printf '{}')
  fi
  printf '%s' "$PROJECTS_JSON"
}

# key=value lines of the project config, one per setting, flattened.
#
# `features.images = true` is nested two deep in the Nix attrset and Incus wants
# the dotted key, so objects are expanded one level and everything else is
# emitted as-is. That covers both shapes the map uses without a schema:
#
#   description   = "..."          -> description=...
#   features.images = true          -> features.images=true
project_settings() {
  projects_json | jq -r --arg p "$1" '
    .[$p] // {} | to_entries[] |
    if (.value | type) == "object"
    then (.key as $outer
          | .value | to_entries[]
          | "\($outer).\(.key)=\(.value)")
    else "\(.key)=\(.value)"
    end'
}

# Create the project if it is missing, then converge its config keys.
#
# Idempotent, diffed key by key, and a no-op on every run once it is right --
# which is the property everything else in this script is built on. The point is
# that a project is described in the repository instead of being something a
# human typed into a live Incus once and never wrote down. `grep -rn 'incus
# project' nixos/` returned nothing at all before this.
ensure_project() {
  [[ -n $PROJECT ]] || return 0
  # --check promises to change nothing. It still *reports* on the project, so a
  # missing one shows up as drift rather than being silently created.
  if [[ $CHECK_ONLY == 1 ]]; then
    if ! incus project show "$PROJECT" >/dev/null 2>&1; then
      step "Incus project $PROJECT does not exist; --check will not create it"
    fi
    return 0
  fi

  if ! incus project show "$PROJECT" >/dev/null 2>&1; then
    step "creating Incus project $PROJECT"
    # Plain create: it defaults features.images to false, which is what we want
    # immediately after. The loop below then flips it to whatever the flake says.
    # Creating it with the final value instead would expose default's images to
    # the project for the duration of the call, which is the confusion that
    # features.images=false was originally set to avoid.
    incus project create "$PROJECT"
  fi

  local key value have
  while IFS='=' read -r key value; do
    [[ -n $key ]] || continue
    # Read the whole project once, not once per key. `incus project show` is
    # YAML-only -- there is no --format json on it, and piping that into jq dies
    # with "Invalid numeric literal at line 1, column 2" -- so the read goes
    # through `incus query`, which is JSON.
    if [[ ! -v PROJECT_JSON ]]; then
      PROJECT_JSON=$(incus query "/1.0/projects/$PROJECT" 2>/dev/null || printf '{}')
    fi
    have=$(project_field "$PROJECT_JSON" "$key")
    [[ $have == "$value" ]] && continue
    step "setting $PROJECT $key = $value (was '${have:-unset}')"
    # ...and write them back through two different channels, because
    # `description` is a top-level field and NOT a configuration key:
    #
    #   incus project set probe3 description=x
    #     Error: Invalid project configuration key "description"
    #
    # Exactly the trap ensure_volumes already documents for volume descriptions,
    # and it cost a full reconcile failure for a purely cosmetic field: the run
    # got as far as printing "setting forgejo description" and then died, before
    # touching anything load-bearing. Everything under features/ is a config key
    # and goes through `project set`; everything else is a top-level field and
    # goes through the API.
    if [[ $key == features.* ]]; then
      incus project set "$PROJECT" "$key=$value"
    else
      incus query -X PATCH "/1.0/projects/$PROJECT" \
        -d "$(jq -cn --arg k "$key" --arg v "$value" '{($k): $v}')"
    fi
    # Invalidate: a PATCH may have changed other fields, and `project set` may
    # have changed the config.
    unset PROJECT_JSON
  done < <(project_settings "$PROJECT")
  unset PROJECT_JSON
}

# One setting of one project, as a string, or empty.
#
# The features./ prefix is the whole of the distinction, and it is not a guess:
# `incus project set` rejects anything outside the config namespace with
# "Invalid project configuration key", so anything reaching the other branch is
# a field the config namespace does not contain.
project_field() {
  jq -r --arg k "$2" '
    if ($k | startswith("features."))
    then (.config[$k] // "")
    else (.[$k] // "")
    end' <<<"$1"
}

incus_run() {
  local -a pargs=()
  [[ -n $PROJECT ]] && pargs=(--project "$PROJECT")
  log "incus $(printf '%q ' "${pargs[@]}" "$@")"
  incus "${pargs[@]}" "$@" </dev/null
}

# Same, but the caller's stdin survives.
#
# incus_run's </dev/null is what stops a pipe left on stdin by a loop from being
# sent as an HTTP request body, and it is not optional. But render_secrets
# genuinely pipes the secret in, and routing it through incus_run silently
# delivered nothing:
#
#   -r-------- 1 root root 0 caddy-env
#
# A zero-byte EnvironmentFile, which Caddy then rejected for having an empty API
# token -- so the symptom was "Caddy will not start" with nothing pointing at the
# cause. The two callers have genuinely different needs, so they are two
# functions rather than a flag.
incus_run_stdin() {
  local -a pargs=()
  [[ -n $PROJECT ]] && pargs=(--project "$PROJECT")
  log "incus $(printf '%q ' "${pargs[@]}" "$@")"
  incus "${pargs[@]}" "$@"
}

# --------------------------------------------------------------------------
# The same logging, for `incus query`, and deliberately WITHOUT --project.
# --------------------------------------------------------------------------
# The flag is not ignored on this subcommand, it is refused outright:
#
#   incus --project forgejo query /1.0/projects/forgejo
#     Error: --project cannot be used with the query command
#
# It appears in the global flag list right next to --project, so routing these
# through incus_run looks correct and is not. The project can only be expressed
# as a query parameter on the URL, which is what project_qs() builds.
#
# This is a whole function rather than a "don't" comment on the call site because
# `incus_run query` is the natural thing to write and there is exactly one call
# site today. The test asserts the string appears nowhere in the file, so a later
# edit that reaches for incus_run out of habit fails immediately.
incus_api() {
  log "incus query $*"
  incus query "$@" </dev/null
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

# Per-instance Incus project, or empty for Incus's `default`.
#
# Read from the flake rather than taken from the command line, because one
# --project cannot describe a set that spans two projects, and `--all` is run
# every fifteen minutes by incus-reconcile.timer. An explicit --project on the
# command line still wins, so a single instance can be reconciled by hand
# without consulting the map.
#
# The map lives beside the registry rather than inside each spec because it is
# consulted per instance during one invocation; embedding it in the spec would
# mean a second nix eval per instance to read one string.
instance_project() {
  local name=$1
  # An explicit --project wins, so a single instance can be reconciled by hand
  # without consulting the map.
  #
  # This reads PROJECT_OVERRIDE and NOT PROJECT, and that distinction is the
  # whole point. PROJECT is reassigned per instance, so guarding on it means
  # the *previous* instance's project leaks into the next lookup: caddy set it
  # empty, forgejo set it to "forgejo", and wireguard then saw a non-empty
  # PROJECT, returned early, and was reconciled in forgejo's project --
  # reporting "no instance named wireguard -- would create it" for an instance
  # that was running. On a two-project set that is a duplicate-recreate on every
  # fifteen-minute reconcile.
  [[ -n $PROJECT_OVERRIDE ]] && { printf '%s' "$PROJECT_OVERRIDE"; return; }
  # Ask for the whole map once per call rather than a per-name attribute path.
  # An unmapped name is an *eval error*, not an empty string -- "does not
  # provide attribute incusInstanceProjects.wireguard" -- and the `||` fallback
  # does not rescue it, because the failing command is inside a command
  # substitution whose exit status the assignment discards. The result was that
  # PROJECT kept whatever the previous instance had set, so caddy's successor
  # was reconciled in caddy's project: `wireguard` came back "no instance named
  # wireguard -- would create it" while it was running, and --all on a
  # two-project set would have recreated instances as duplicates.
  #
  # Reading one jq lookup off the map cannot fail that way: a missing key is
  # null, and //'' turns it into the empty string that means "default project".
  nix eval --json "$FLAKE_DIR#incusInstanceProjects" 2>/dev/null \
    | jq -r --arg n "$name" '.[$n] // ""' \
    || printf ''
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
  local name=$1 kind=$2 sq_out md_out
  local -a roots metadata_files

  step "building image"

  # The only thing that differs between a container and a VM is where the rootfs
  # comes from: a squashfs for a container, a qcow2 disk for a VM. Both get a
  # metadata tarball the same way, because lxc-instance-common.nix -- imported
  # by both lxc-container.nix and incus-virtual-machine.nix -- pulls in
  # lxc-image-metadata.nix, so system.build.metadata exists either way.
  #
  # A VM is *not* a single-artefact import. That was wrong when first written,
  # and it cost a failed deploy to find out: `incus image import` takes
  # `(<tarball>|<directory>|<URL>) [<rootfs tarball>]`, and the first argument is
  # always the metadata source. Handing it a bare .qcow2 makes Incus read the
  # disk as a metadata tarball and fail with
  #   Error: Metadata tarball is missing metadata.yaml
  # Both kinds therefore pass two arguments, and the VM type is inferred by the
  # Incus CLI from the rootfs filename ending in .qcow2.
  if [[ $kind == vm ]]; then
    sq_out=$(nix build "$FLAKE_DIR#nixosConfigurations.$name.config.system.build.qemuImage" \
      --no-link --print-out-paths)
  else
    sq_out=$(nix build "$FLAKE_DIR#nixosConfigurations.$name.config.system.build.squashfs" \
      --no-link --print-out-paths)
  fi

  shopt -s nullglob
  if [[ $kind == vm ]]; then
    roots=("$sq_out"/*.qcow2)
  else
    # .img is what older nixpkgs emitted, .squashfs what current emits.
    roots=("$sq_out"/*.squashfs "$sq_out"/*.img)
  fi
  shopt -u nullglob

  [[ ${#roots[@]} -eq 1 ]] || die "expected one rootfs image in $sq_out, found ${#roots[@]}"

  md_out=$(nix build "$FLAKE_DIR#nixosConfigurations.$name.config.system.build.metadata" \
    --no-link --print-out-paths)

  shopt -s nullglob
  metadata_files=("$md_out"/tarball/*.tar.xz "$md_out"/*.tar.xz)
  shopt -u nullglob

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
  incus_run image list "$1" --format json 2>/dev/null \
    | jq -r --arg a "$1" 'map(select(any(.aliases[]?; .name == $a))) | .[0].fingerprint // empty'
}

# The store path of the squashfs the image at an alias was built from. This is
# how we recognise "already have this exact image" without importing it.
image_build_source() {
  incus_run image get-property "$1" user.build-source 2>/dev/null || true
}

# Any image in the pool built from this exact squashfs. Used to recover from an
# alias that names a stale image when the wanted content is already present.
image_with_build_source() {
  incus_run image list --format json 2>/dev/null \
    | jq -r --arg s "$1" '.[] | select(.properties["user.build-source"] == $s) | .fingerprint' \
    | head -1
}

# Remove an alias of this name from every project EXCEPT the one this run
# reconciles into.
#
# WHY THIS EXISTS. `point_alias_at` only ever creates an alias; nothing in this
# script ever removed one. That is invisible until an instance MOVES between
# projects, at which point the alias it left behind has no owner and can never be
# cleaned up by anything. Measured on the live pool after forgejo moved into its
# own project:
#
#   project default   homelab/forgejo -> 082a11388142   rev ee3c0279   (orphan)
#   project forgejo   homelab/forgejo -> 7a35c719a409   rev 14eb1122   (live)
#
# Aliases are project-scoped, so the name exists twice, in two projects, pointing
# at different images. Two consequences, both bad:
#
#   * The orphan is uncollectable. incus-image-gc keeps an image that holds an
#     alias, and this one held it in the wrong project -- so 20 duplicates and one
#     324 MB stale image survived a GC that was otherwise flawless.
#   * It is a trap for anyone scripting. Incus does not resolve image aliases on
#     most verbs, so `incus image delete homelab/forgejo` resolves to the DEFAULT
#     project's copy -- the wrong one -- and the real image survives.
#
# So this runs on every reconcile: for each project other than ours, if it holds
# an alias with this name, delete it. Only ever the OTHER projects', and only ever
# this exact alias, so it cannot touch an instance that legitimately lives there.
# Drop this alias from every project other than the one we reconcile into.
#
# WHY THIS EXISTS. `point_alias_at` only ever creates an alias; nothing in this
# script ever removed one. That is invisible until an instance MOVES between
# projects, at which point the alias it left behind has no owner and can never be
# cleaned up by anything. Measured on the live pool after forgejo moved into its
# own project:
#
#   project default   homelab/forgejo -> 082a11388142   rev ee3c0279   (orphan)
#   project forgejo   homelab/forgejo -> 7a35c719a409   rev 14eb1122   (live)
#
# Aliases are project-scoped, so the name exists twice, in two projects, pointing
# at different images. Two consequences, both bad:
#
#   * The orphan is uncollectable. incus-image-gc keeps an image that holds an
#     alias, and this one held it in the WRONG project -- so a 324 MB stale image
#     survived a GC that was otherwise flawless, and needed deleting by hand.
#   * It is a trap for anyone scripting. Incus does not resolve image aliases on
#     most verbs, so `incus image delete homelab/forgejo` resolves to the default
#     project's copy -- the wrong one -- and the live image survives untouched.
#
# So this runs on every reconcile: for each project other than ours, if it holds an
# alias of this name, delete it. Only ever the other projects', and only ever this
# one alias, so it cannot touch an instance that legitimately lives in one of them.
#
# Never removes an IMAGE, only an alias. The image behind it becomes unaliased and
# is then collected by incus-image-gc on its own schedule, which is the component
# that owns image lifetime.
# Every project Incus actually has, one per line.
#
# From Incus rather than from the flake's `incusProjects` map, and that is the
# whole point: the orphan this exists to find is by definition in a place the
# registry no longer describes. Reading the projects the flake knows about would
# miss it -- and the flake is also cached in $PROJECTS_JSON for the whole run,
# so it cannot see a project created since. `incus project list --format json`
# is asked for directly because `incus query` does not resolve aliases and
# `incus project list --format csv` is not CSV (it is the table format, whose
# first line is the header and whose current project is decorated "(current)").
incus_project_names() {
  incus_run project list --format json 2>/dev/null | jq -r '.[].name'
}

drop_foreign_aliases() {
  local alias=$1 project=$2 other
  [[ -n $project ]] || return 0
  local -a strays=()
  while read -r other; do
    [[ -n $other && $other != "$project" ]] || continue
    # `any` over the alias list, so an image with no aliases at all -- which is
    # what an empty project returns -- is a clean "no" rather than an error.
    if [[ $(incus_run image list --project "$other" --format json 2>/dev/null \
              | jq -r --arg a "$alias" \
                  'any(.[]; any(.aliases[]?; .name == $a))') == true ]]; then
      strays+=("$other")
    fi
  done < <(incus_project_names 2>/dev/null)
  [[ ${#strays[@]} -gt 0 ]] || return 0
  if [[ $CHECK_ONLY == 1 ]]; then
    for other in "${strays[@]}"; do
      warn "$alias also exists in project '$other', which no instance owns;" \
           "it would be removed"
    done
    return 0
  fi
  for other in "${strays[@]}"; do
    if incus_run image alias delete "$alias" --project "$other" >/dev/null 2>&1; then
      step "removed the orphaned $alias from project '$other'"
    else
      warn "$alias is still present in project '$other' and could not be removed."
      warn "  It keeps that image alive and incus-image-gc will not collect it."
      warn "  Remove it by hand:  incus image alias delete $alias --project $other"
    fi
  done
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

# A copy of the metadata tarball whose description names this instance.
#
# WHY THIS EXISTS. Incus derives an image fingerprint from the METADATA tarball, and
# nixpkgs' lxc-image-metadata.nix generates ours per nixpkgs revision -- the file is
# named nixos-image-lxc-<nixpkgs>-x86_64-linux.tar.xz and nothing in it varies by
# configuration. So caddy's image and wireguard's image, built from one nixpkgs, have
# IDENTICAL metadata and therefore the same fingerprint, and the second import is
# refused:
#
#   Error: Image with same fingerprint already exists
#
# Which means every instance collides with the previous one on every rebuild, and
# the pool fills with images that can never be told apart by content. Confirmed on
# the live instance: 22 unaliased images, two of them carrying the same
# user.build-source as the aliased image and differing in size by 4096 bytes -- which
# cannot happen if the fingerprint tracked the rootfs.
#
# The description is the only field in metadata.yaml that is ours to choose, and
# changing it is enough. Measured, on the running instance, by rewriting only that
# one field and importing the previously-refused rootfs:
#
#   Error: Image with same fingerprint already exists   <- original metadata
#   Image imported with fingerprint: 560477927d41...     <- description says "caddy"
#
# So each instance gets a fingerprint of its own, and "already exists" comes to mean
# what it says: this exact image is already here.
#
# Everything else in the tarball -- the nix store registration, the path
# registration -- is copied through untouched, because those decide whether the
# container's binaries resolve and they must not be second-guessed here.
per_instance_metadata() {
  local src=$1 instance=$2 work version
  work=$(mktemp -d)
  tar -xJf "$src" -C "$work" || die "cannot unpack $src"
  # The description, and nothing else. Spelled as a substitution on the JSON field
  # rather than a YAML edit because metadata.yaml is machine-generated JSON, and a
  # pretty-printed YAML rewrite of a file nixpkgs emits as one line is the kind of
  # change that silently stops matching.
  #
  # The version is read out of the description the module generated, not from
  # `nixos-version`: that tool is not on the reconciler's PATH, and a `\$(...)`
  # inside these double quotes survives as a LITERAL command substitution and ends up
  # inside the description string. Both were found by the test rather than by reading.
  local version
  version=$(sed -n 's/.*lxc-\([^ ]*\) x86_64.*/\1/p' "$work/metadata.yaml" | head -1)
  sed -i "s|\"description\":\"[^\"]*\"|\"description\":\"$instance $version\"|" \
    "$work/metadata.yaml" \
    || die "cannot rewrite the description in $src"
  grep -q "\"description\":\"$instance " "$work/metadata.yaml" \
    || die "the description rewrite did not take in $src"
  # Repacked with the same format and a fixed mtime, so the same instance always
  # produces the same tarball. Without -i, tar embeds the current time and every
  # reconcile would produce a different fingerprint for the same build.
  #
  # The output goes in a SECOND directory, not in $work. This is not tidiness.
  # `tar -cJf "$work/metadata.tar.xz" -C "$work" .` writes the archive into the
  # very directory it is archiving, and whether the archive then lists ITSELF is a
  # race between tar walking the directory and xz creating the file. Measured, ten
  # runs of the same input:
  #
  #   run 1: ./ ./metadata.yaml ./nix-path-registration
  #   run 2: ./ ./metadata.tar.xz ./metadata.yaml ./nix-path-registration   <-- self
  #   run 3: ./ ./metadata.yaml ./nix-path-registration
  #
  # and tar says so out loud on about half of them:
  #
  #   tar: .: file changed as we read it
  #
  # So the metadata tarball was NOT reproducible. Incus derives an image
  # fingerprint from the METADATA tarball, so a self-member intermittently changes
  # the fingerprint of an unchanged build, the reconciler stops recognising the
  # image it already imported, and every so often an instance is recreated and a
  # duplicate image lands in the pool. That is the same symptom the per-instance
  # metadata repack was introduced to fix, reintroduced from the other side, and it
  # is why the pool had accumulated so many unaliased images of the same build.
  #
  # Writing to a separate directory removes the race by construction: there is no
  # file for tar to trip over. Verified: ten runs, ten identical hashes, and no
  # warning.
  local out
  out=$(mktemp -d)
  tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner \
      --mtime=@1 -cJf "$out/metadata.tar.xz" -C "$work" . \
    || die "cannot repack $src"
  printf '%s\n' "$out/metadata.tar.xz"
}

# Echo the fingerprint the instance should be based on.
import_image() {
  local rootfs=$1 metadata_tarball=$2 alias=$3 rev=$4
  local output fingerprint instance_metadata

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
    # Unconditional, and two arguments for a VM exactly as for a container.
    # There is no --type flag on `incus image import`: the Incus CLI derives the
    # image type from the rootfs filename's extension, sending it as the
    # `rootfs.img` multipart part when it ends in .qcow2 and `rootfs`
    # otherwise (cmd/incus/image.go). So a VM needs its metadata tarball just as
    # much as a container does -- a bare .qcow2 on its own is read as the
    # metadata source and rejected.
    #
    # Deliberately no --reuse: it deletes an existing image that already carries
    # the alias.
    #
    # incus_run, and this line is the entire reason the project move could not
    # work. Images are project-scoped exactly like volumes:
    #
    #   incus image list                    -> 22 images
    #   incus image list --project forgejo  -> none
    #   incus create --project forgejo <a fingerprint from default>
    #     Error: Image "082a1138..." not found
    #
    # With a bare `incus` the image was imported into `default` while every check
    # around it read through incus_run and therefore looked in the forgejo
    # project. The run imported into the wrong project, resolved no fingerprint,
    # and died on
    #   ERROR: homelab/forgejo resolved to no fingerprint after import
    # with the image sitting in the project it was not asked for.
    #
    # The captured $output now also carries incus_run's own log line, because
    # 2>&1 catches the stderr it writes to. Harmless for the "already exists"
    # match below, and in the failure message it means the error is preceded by
    # the exact invocation -- which is the thing you want there anyway.
    # The metadata handed to Incus is this instance's own copy, so the fingerprint is
    # this instance's. See per_instance_metadata for why the stock one cannot work.
    instance_metadata=$(per_instance_metadata "$metadata_tarball" "$alias")

    if output=$(incus_run image import "$instance_metadata" "$rootfs" --alias "$alias" 2>&1); then
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
      # The build we want may not be in the pool at all, and "already exists" says
      # nothing about which of two possibilities this is.
      #
      # Incus derives an image fingerprint from the METADATA tarball, not the rootfs.
      # Ours is generated per nixpkgs revision and is byte-identical across every
      # instance built from it -- the file is named
      # nixos-image-lxc-<nixpkgs>-x86_64-linux.tar.xz and nothing in it varies by
      # configuration. So importing caddy's and wireguard's images from one nixpkgs
      # collides on the fingerprint even when the rootfs differs completely, and the
      # second import is refused:
      #
      #   Error: Image with same fingerprint already exists
      #
      # Measured on the live pool: two images carrying the SAME user.build-source and
      # differing in size by 4096 bytes. That cannot happen if the property is derived
      # from the rootfs, and is exactly what happens if the fingerprint is not.
      #
      # So user.build-source is a reliable key for finding an image -- it is written
      # only after the alias is known to name one -- and an unreliable way to answer
      # "is this build already here".
      step "fingerprint already in the pool -- deciding whether it holds THIS build"
      fingerprint=$(image_with_build_source "$rootfs")
      if [[ -n $fingerprint ]]; then
        # The good case: the alias was pointing elsewhere, and this image provably
        # holds the build we want.
        step "  the pool does hold this exact build; re-pointing $alias at it"
        point_alias_at "$alias" "$fingerprint"
      else
        # The build is NOT here. Whatever holds the fingerprint was made from
        # different content, so there is nothing to re-point at. Deleting the
        # colliding image buys exactly one run -- the next build collides again --
        # so this is reported as the design fault it is.
        die "$alias: the image at this fingerprint is NOT this build."$'\n'\
            "  Incus takes the fingerprint from the metadata tarball, and ours is"$'\n'\
            "  identical for every instance built from this nixpkgs revision -- so"$'\n'\
            "  two instances collide and the second import is refused."$'\n'\
            "  No image in the pool carries:"$'\n'\
            "    user.build-source = $rootfs"$'\n'\
            "  which is the build just made, so the content is genuinely absent."$'\n'\
            "  Deleting the colliding image would only buy one run; the next build"$'\n'\
            "  collides again. See incus/README.md, 'Image identity'."
      fi
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
  #
  # incus_run on the read: it was a bare `incus image get-property`, which reads
  # the alias in `default` even while everything around it reads the forgejo
  # project. The value it returned was the wrong image's, so it never matched
  # and this PATCH was re-issued on every single run.
  if [[ -n $rev ]] && [[ $(incus_run image get-property "$alias" user.flake-rev 2>/dev/null || true) != "$rev" ]]; then
    incus_run image set-property "$alias" "user.flake-rev=$rev"
  fi

  printf '%s\n' "$fingerprint"
}

instance_exists() {
  incus_run info "$1" >/dev/null 2>&1
}

# Reconcile Incus's boot.autostart from the spec's autostart.
#
# Split out of the apply path so it can be tested directly, and because it is a
# self-contained decision: read the current value, set it only if it differs.
#
# `autostart` in a spec means two things that used to be conflated. Deciding
# whether to start the instance *now* is handled by the caller. This function
# handles the part that nothing was handling: whether the instance comes back
# after the host reboots, which is Incus's own `boot.autostart` and defaults to
# false. All three instances had it unset, so a host reboot with a clean tree
# would have brought up no Caddy, no Forgejo and no VPN -- masked only by the
# incus-apply-<name>.path units firing on every edit under the repo.
#
# `autostart = false` is deliberately not honoured here. That field means "do not
# start this on apply"; a service stopped on purpose should still be startable at
# boot, so a deliberate stop does not silently become unbootable.
reconcile_boot_autostart() {
  local name=$1 spec=$2 current_boot
  # Compared against the literal string "true", not via jq's // operator: // treats
  # false as empty, so it would report every instance as needing a change and
  # re-issue the set on every run, forever.
  current_boot=$(instance_field "$name" '.config["boot.autostart"] // ""')
  if [[ $current_boot != true ]]; then
    step "setting boot.autostart = true"
    incus_run config set "$name" "boot.autostart=true"
  fi
}

instance_field() {
  instance_json "$1" | jq -r "$2"
}

# Raw JSON for one instance, project-scoped. The single place an instance is
# fetched over the API.
#
# This used to be spelled out longhand at each of three call sites, and two of
# them left the project off:
#
#   incus query "/1.0/instances/$1?project=$PROJECT"     instance_field  (right)
#   incus query "/1.0/instances/$name"                   sync_devices   (wrong)
#   incus query "/1.0/instances/$name"                   check mode     (wrong)
#
# Both wrong ones are quiet failures. A 404 makes `incus query` exit non-zero, so
# under `set -e` inside a command substitution assigned to `current`... the
# substitution's status is discarded by the assignment, so execution continues
# with `current` empty and jq never runs at all. sync_devices then compares an
# empty device set against the spec and re-applies every device, forever, while
# --check reports drift on an instance that is perfectly correct. One helper,
# because "did you remember ?project=" is not a question to ask three times.
instance_json() {
  incus query "/1.0/instances/$1$(project_qs)"
}

ensure_volumes() {
  local name=$1 spec=$2 kind=$3 volume pool volume_name description current
  local vtype
  local schedule expiry compact units distinct
  local volume_url volume_json current_schedule current_expiry
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

    # A container's data volume is a filesystem Incus mounts at `path`. A VM
    # cannot have that: a guest gets raw block devices and mounts them itself,
    # so its data volume has *block content*.
    #
    # `block` is a content type, not a volume type. Incus's volume types are
    # container / custom / virtual-machine / image, and both a container's data
    # volume and a VM's data disk are `custom` -- they differ only in
    # content_type. So the API path below is `custom` either way, while the
    # content type is what actually has to differ, and it is passed to
    # `storage volume create --type`.
    #
    # Getting this wrong is not subtle but is easy to reason about wrongly:
    #   Error: Invalid storage volume type name
    # from the PATCH, because `/volumes/block/` is not a route.
    #
    # Default by instance type rather than making every spec say so, so adding a
    # volume to a container keeps working unchanged.
    vtype=$(jq -r '.type // empty' <<<"$volume")
    if [[ -z $vtype ]]; then
      if [[ $kind == vm ]]; then vtype=block; else vtype=filesystem; fi
    fi
    case $vtype in
      block|filesystem) ;;
      *) die "$name's volume $volume_name has content type '$vtype' (want block or filesystem)" ;;
    esac

    # Pool and volume are separate positional arguments, not "pool/volume":
    #   incus storage volume show [<remote>:]<pool> [<type>/]<volume>
    # Passing one combined string parses as pool=backup with the volume
    # missing, so the command fails even when the volume is there -- and the
    # code below then tries to create it and dies with
    #   Error: Volume by that name already exists
    # on every run after the first. Verified against `incus storage volume
    # show --help` rather than guessed.
    #
    # incus_run, not bare incus: volumes are project-scoped. The bare call
    # checked `default`, so for an instance in the forgejo project it always
    # reported "missing" and the next line tried to create a volume that already
    # existed -- reproducing the very error the comment above warns about, from
    # a completely different cause.
    if ! incus_run storage volume show "$pool" "$volume_name" >/dev/null 2>&1; then
      step "creating volume $pool/$volume_name ($vtype)"
      incus_run storage volume create "$pool" "$volume_name" --type "$vtype"
    fi

    # Snapshot policy, declared per volume in the volume's OWN entry rather than
    # in a list somewhere with the rest of the backup settings. That placement
    # is the reason this is worth reconciling at all: when Minecraft finishes
    # moving out of k3s, its volume entry carries its own policy and there is no
    # global list anyone has to remember to update.
    #
    # Omitting the key means never scheduled, which is what keeps
    # forgejo-runner-data -- a runner token and a cache -- out of it without a
    # special case anywhere.
    #
    #   snapshots.schedule  a cron expression, a comma-separated list of Incus
    #                       aliases (@hourly @daily @midnight @weekly @monthly
    #                       ...), or empty to disable automatic snapshots
    #   snapshots.expiry    one duration expression, stamped onto each snapshot
    #                       as it is taken
    #
    # Neither is retroactive: expiry is added to the time of the NEXT snapshot,
    # so snapshots that already exist keep the date they were given.
    schedule=$(jq -r '.snapshots.schedule // empty' <<<"$volume")
    expiry=$(jq -r '.snapshots.expiry // empty' <<<"$volume")

    # expiry is validated here and nowhere else, because Incus documents its
    # grammar completely: an expression like `1M 2H 3d 4w 5m 6y`, with the note
    # "Each unit may only be specified once." That makes it a closed set --
    # S seconds, M minutes, H hours, d days, w weeks, m months, y years.
    #
    # Worth catching because expiry is the one setting that decides how long a
    # rollback stays available, and a value nobody can parse is a value whose
    # retention nobody can predict. Checked BEFORE anything is written, so a bad
    # value cannot leave a volume half-applied.
    #
    # `infinite` is passed through rather than refused. Whether Incus honours it
    # is not established here, and a validator that rejects a value the API
    # would have accepted fails in the direction that blocks an operator for no
    # gain; an unrecognised value is Incus's to reject, loudly, on the spot.
    #
    # schedule is deliberately NOT validated. Incus parses the cron expression
    # itself and owns the alias list, so any copy of those rules here is a
    # second, frozen one -- and it would break by refusing a value Incus
    # accepts, the day Incus grows an alias.
    if [[ -n $expiry && $expiry != infinite ]]; then
      compact=${expiry//[[:space:]]/}
      units=${compact//[0-9]/}
      [[ $compact =~ ^([0-9]+[SMHdwmy])+$ ]] \
        || die "$name's volume $volume_name has snapshots.expiry '$expiry', which is not a duration expression (want something like 7d, or 1M 2H 3d)"
      distinct=$(printf '%s' "$units" | fold -w1 | sort -u | wc -l)
      [[ $distinct -eq ${#units} ]] \
        || die "$name's volume $volume_name repeats a unit in snapshots.expiry '$expiry'; each of S M H d w m y may be given at most once"
    fi

    # One API read for all three fields. Read via the API, not `incus storage
    # volume show`: that prints YAML, and piping it to jq dies with
    #   jq: parse error: Invalid numeric literal at line 1, column 7
    # `custom` for every volume here, whatever its content type. See the note
    # above: `block` is a content type and `/volumes/block/` is not a route.
    #
    # $(project_qs), because `incus query` does not translate --project onto
    # the URL. Without it this 404s for a project-scoped volume and `current`
    # comes back empty, so every field below is re-PATCHed on every single run
    # -- a write on every sweep of the fifteen-minute timer, for values that are
    # already correct.
    volume_url="/1.0/storage-pools/$pool/volumes/custom/$volume_name$(project_qs)"
    #
    # Unconditional. An earlier version of this skipped the read whenever the
    # spec declared nothing to set, on the reasoning that there was then nothing
    # to compare -- which is exactly backwards: a spec that says nothing is the
    # case where the volume may carry a schedule that has to be CLEARED. It read
    # as "current is unset, desired is unset, they agree", and the volume could
    # never be un-snapshotted by editing the repository, which is the only way
    # an operator has to remove one. Found by section 5 of
    # incus/apply-snapshots-test.sh, which exists for the clearing case and
    # nothing else.
    volume_json=$(incus query "$volume_url")

    # Three fields, one read, one PATCH.
    #
    # One PATCH and not three is the fix, and the reason is an asymmetry in
    # Incus's own handler (storage_volumes.go, storagePoolVolumePatch):
    #
    #   for k, v := range dbVolume.Config {
    #     if _, ok := req.Config[k]; !ok { req.Config[k] = v }
    #   }
    #   err = pool.UpdateCustomVolume(..., req.Description, req.Config, op)
    #
    # Config is merged key by key -- the loop is right there. Description is not
    # merged: it is assigned from the request body, and a body that omits the
    # field decodes to Go's zero value, so whatever was there is overwritten
    # with nothing.
    #
    # This block used to PATCH the description, then PATCH the schedule, then
    # PATCH the expiry, in that order. Every one of those calls succeeded, and
    # every pass ended with a blank description, which the following pass
    # repaired from a path nobody was reading. That is why it shipped green:
    # six volumes in a row, every volume declaring `snapshots` lost its
    # description and every volume declaring none kept its own, and the suite
    # modelled the handler as merging description when the handler assigns it.
    # Section 13 of incus/apply-snapshots-test.sh is the test.
    #
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
    current=$(jq -r '.description // ""' <<<"$volume_json")

    # Reconciled in both directions, including to empty. Dropping `snapshots`
    # from a volume entry is how a volume stops being snapshotted, and a value
    # set once by hand would otherwise outlive the declaration that justified
    # it, with no route back to "unscheduled" except editing Incus directly.
    # apply_limits already clears a key the spec omits; this is the same
    # contract. It is announced rather than silent because this is the one
    # cleared field where the cost is disk rather than memory.
    current_schedule=$(jq -r '.config["snapshots.schedule"] // ""' <<<"$volume_json")
    current_expiry=$(jq -r '.config["snapshots.expiry"] // ""' <<<"$volume_json")

    # The spec's description when the spec has one, the volume's own when it
    # does not. That second half is what keeps this from becoming the
    # mirror-image bug: an empty description in the spec means "no spec entry
    # manages this", and "no spec entry manages this" must not be spelled
    # "empty" in the body. caddy-secrets and wireguard-data each carry a
    # description no entry in the flake mentions.
    desired=$current
    if [[ -n $description ]]; then
      desired=$description
    fi

    # Announced before written, as the snapshot fields always were. The
    # description was the silent one, and the silence is most of why this took
    # a day to find.
    desc_change=0
    if [[ $desired != "$current" ]]; then
      desc_change=1
      step "$volume_name: description ${current:-unset} -> ${desired:-unset}"
    fi
    schedule_change=0
    if [[ $schedule != "$current_schedule" ]]; then
      schedule_change=1
      step "$volume_name: snapshots.schedule ${current_schedule:-unset} -> ${schedule:-unset}"
    fi
    expiry_change=0
    if [[ $expiry != "$current_expiry" ]]; then
      expiry_change=1
      step "$volume_name: snapshots.expiry ${current_expiry:-unset} -> ${expiry:-unset}"
    fi

    # Nothing changed, so nothing is written. incus-reconcile.timer runs this
    # every fifteen minutes and a quiet sweep has to still mean something.
    if (( desc_change || schedule_change || expiry_change )); then
      # description is unconditional. The config keys appear only when they
      # differ, which is what stops a volume with no policy declared from
      # having an empty snapshots.expiry written onto it as an explicit clear
      # -- and "unset" and "cleared" look identical in `incus storage volume
      # list`, so that would be a write nobody could see and nobody asked for.
      #
      # `*` and not `+`: jq's `+` on two objects is a shallow merge, so the
      # second {config: ...} would replace the first and quietly drop
      # snapshots.schedule from the body. `*` is the recursive one.
      incus_api -X PATCH \
        -d "$(jq -cn \
                --arg d "$desired" --arg s "$schedule" --arg e "$expiry" \
                --arg sc "$schedule_change" --arg ec "$expiry_change" \
              '{description: $d}
               * (if $sc == "1" then {config: {"snapshots.schedule": $s}} else {} end)
               * (if $ec == "1" then {config: {"snapshots.expiry": $e}} else {} end)')" \
        "$volume_url"
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

# The root disk of a VM, sized through the `root` disk device's own `size`
# key -- `size` on `root` is what the Incus documentation points at for
# resizing a `virtual-machine/*` volume.
#
# NOT `limits.disk.size`. That is a different key, it is rejected on a VM,
# and its rejection is what makes this function look necessary at all.
#
# `root` arrives from a profile (the `default` one), and Incus refuses to
# modify a profile device on a single instance:
#
#   Error: Device from profile(s) cannot be modified for individual instance.
#   Override device or modify profile instead
#
# and the profile cannot carry the size, because `default` is shared with
# every other instance on the host -- caddy, forgejo, wireguard would all
# inherit a runner-sized disk. So the size goes on an instance-local OVERRIDE
# of `root`, which copies the profile's device and adds our key to the copy.
# Two commands, because the second only works once the first has run:
#
#   override  ->  Error: The device already exists   (if root is already local)
#   set       ->  Error: ...cannot be modified...    (if root is still inherited)
#
# Neither is reconciled by sync_devices, which is correct: that diffs devices
# and applies a change by remove-then-add, because a device's type cannot be
# changed in place -- and doing that to `root` would destroy the instance's
# root disk. Hence a field of its own in the spec and an in-place write here.
# root is otherwise never touched by this script, and that invariant is
# load-bearing (see the removal loop in sync_devices).
#
# A container's rootfs is a filesystem, not a disk, so `size` on its root
# device means a storage quota rather than a bigger disk -- and a container
# has no instance-local `root` to override. Nothing to do for one.
#
# Never cleared. Incus does not shrink a VM's root disk, so unsetting the key
# would not hand any space back -- it would only make every subsequent run
# report drift that no apply can resolve. Warn instead.
apply_root_disk_size() {
  local name=$1 spec=$2 kind=$3 want have has_root devices

  [[ $kind == vm ]] || return 0

  want=$(jq -r '.rootDiskSize // empty' <<<"$spec")

  # One query for both facts. They have to agree with each other, and asking
  # twice invites a torn read against an instance apply.sh may be recreating.
  devices=$(instance_json "$name" | jq -c '.devices // {}')
  have=$(jq -r '.root.size // empty' <<<"$devices")
  has_root=$(jq -r '.root != null' <<<"$devices")

  if [[ -z $want ]]; then
    if [[ -n $have ]]; then
      warn "rootDiskSize is unset but root.size is '$have'; Incus cannot shrink a VM root disk, leaving it"
    fi
    return 0
  fi

  if [[ $want == "$have" ]]; then
    return 0
  fi

  step "setting root disk size = $want"
  if [[ $has_root == true ]]; then
    incus_run config device set "$name" root "size=$want"
  else
    # First time: root is still only in the profile, so it has to be
    # overridden onto the instance before a key can be set on it.
    incus_run config device override "$name" root "size=$want"
  fi
  # The guest grows its partition and filesystem at boot (autoResize,
  # boot.growPartition), so the space is not visible to `df` until it
  # restarts. Worth saying out loud: apply.sh reporting success here is
  # not the same as the guest already having the room.
  log "  guest claims the new size at next boot; no reboot from here"
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
  # A helper for the two "is this secret here" questions, because they have
# different causes and the wrong guess sends people away for a while.
#
# A key that is present in secrets.yaml but NOT declared as sops.secrets.<name>
# is never written to /run/secrets at all, and no number of rebuilds changes
# that -- only the declaration does. That is the actual cause this ran into,
# and the message used to blame a missing rebuild, which sent the problem off
# to be fixed twice over by something that could not possibly have fixed it.
#
# So: absent means "not declared", present-but-unreadable means a permissions
# or ownership problem, and only the second is anything to do with activation.
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
  local name=$1 spec=$2 entry file env format mode group source value wanted current unit
  local path dir cur_mode cur_group cur_dir_mode state cmd attempt needs_write
  local changed=0
  local -a entries consumers

  mapfile -t entries < <(jq -c '.renderedSecrets[]?' <<<"$spec")
  [[ ${#entries[@]} -eq 0 ]] && return 0

  [[ $EUID -eq 0 ]] || die "$name declares renderedSecrets but apply.sh is not root"

  for entry in "${entries[@]}"; do
    # `// empty`, not a bare `.file`: jq renders a missing key as the *string*
    # "null", so `[[ -n $file ]]` would pass and the secret would be written to
    # a file literally called "null" inside the instance.
    file=$(jq -r '.file // empty' <<<"$entry")
    format=$(jq -r '.format // "env"' <<<"$entry")
    env=$(jq -r '.env // empty' <<<"$entry")
    mode=$(jq -r '.mode // "0400"' <<<"$entry")
    group=$(jq -r '.group // empty' <<<"$entry")
    source=$(jq -r '.source // empty' <<<"$entry")

    [[ -n $file ]] || die "$name has a renderedSecret with no file name: $entry"
    [[ -n $source ]] || die "$name's $file has no source: $entry"

    # file, mode and group are interpolated into a shell command string below,
    # so they are constrained rather than trusted. `file` in particular is a
    # path component on the way to a `sh -c`, where a space or a semicolon would
    # turn a spec into a command.
    [[ $file =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      || die "$name's renderedSecret has an unusable file name '$file'"
    [[ $mode =~ ^[0-7]{3,4}$ ]] \
      || die "$name's $file has mode '$mode', which is not octal (want e.g. 0440)"
    [[ -z $group || $group =~ ^[a-z_][a-z0-9_-]*\$?$ ]] \
      || die "$name's $file has an invalid group '$group'"

    # "env" writes `KEY=value`, which is what a systemd EnvironmentFile wants.
    # "raw" writes the secret's bytes unchanged, for anything that is not a
    # KEY=value line -- a PEM certificate or private key, for instance, which
    # has newlines and would be silently mangled into one enormous variable.
    case $format in
      env)
        [[ -n $env ]] || die "$name's $file uses format=env but declares no env name"
        ;;
      raw) ;;
      *) die "$name's $file has unknown format '$format' (want env or raw)" ;;
    esac

  assert_secret_readable "$source" "$name's $file"

    # Command substitution strips trailing newlines. For format=env that is
    # exactly right: EnvironmentFile wants one KEY=value per line and no
    # continuation. For format=raw it costs the PEM its final newline, which
    # nothing downstream cares about -- the internal newlines are what matter
    # and those survive.
    value=$(<"$source")

    # A secret that decrypts to nothing is never valid, and writing the empty
    # string produces a file that looks fine and fails somewhere else entirely
    # ("API token '' appears invalid"). Fail here, where the cause is obvious.
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

    # Content AND ownership are both compared, not just content. A file whose
    # bytes are right but whose mode is not is still broken, and the failure mode
    # is the confusing one: the consumer cannot read it and exits, while
    # apply.sh reports that everything is already up to date.
    #
    # `dir`, defaulting to the one directory everything else has always used.
    # It exists for Forgejo, whose NixOS module keeps SECRET_KEY,
    # INTERNAL_TOKEN, JWT_SECRET and LFS_JWT_SECRET at fixed paths under its
    # customDir and generates any of them that is *empty* -- and that generator
    # unit is sandboxed with ReadWritePaths = [customDir]. Point the four at
    # files here instead and the generator would try to create them here, be
    # denied by its own sandbox, and fail a unit that forgejo.service Requires.
    # Writing them where the module already expects them makes the generator a
    # no-op, and needs no mkForce to redirect the module's own defaults.
    dir=$(jq -r '.dir // "/var/lib/incus-secrets"' <<<"$entry")
    path="$dir/$file"
    # incus_run, not bare incus: an instance name resolves against the *current*
    # project, so a bare `incus exec forgejo` fails with "Instance not found" for
    # an instance living in the forgejo project. That would have been the worst
    # of these bugs, because the three reads below already end in `|| true`:
    # every one returns empty, `needs_write` is set for every secret on every
    # run, and render_secrets reports it re-rendered a file that was already
    # correct. Then it restarts the consumers. Forever, silently.
    # Every read goes through the NixOS profile explicitly. The guest's inherited
    # PATH has no coreutils, so a bare `cat`, `stat` or `sha256sum` can fail to
    # resolve and come back empty -- and an empty read is indistinguishable from
    # "file absent" or "content differs", which is what silently pinned the
    # mismatch below in place on every run.
    g() { incus_run exec "$name" -- sh -c "export PATH=/run/current-system/sw/bin:\$PATH; $*" 2>/dev/null || true; }

    # Compared as a digest of the exact bytes, not as a string.
    #
    # `$(cat file)` strips trailing newlines, so a file with one appended newline
    # compared equal to the same secret without it. That is precisely the bug
    # this now catches: apply.sh wrote every secret through a herestring, which
    # appends \n, and then compared the result back through command substitution,
    # which removes it. The file was one byte longer than the secret and
    # apply.sh reported it already correct, forever.
    #
    # It matters for these five because Forgejo derives its TOTP encryption key
    # from SECRET_KEY. The k3s app.ini held 43 bytes with no trailing newline;
    # the rendered file was the same 43 characters plus \n. Whether Forgejo trims
    # when it reads a `*_URI` file decides whether that is harmless, and rather
    # than depend on the answer the file is now written with no trailing newline,
    # so it is byte-identical to the k3s value under either behaviour.
    dir_mode=0711
    if [[ -n $group ]]; then
      # When the consumer group owns the directory, 0700 closes it to everyone
      # else -- which is the whole point of the group. Checked rather than
      # assumed: `stat -c %U` gives a group name on NixOS too, and if the
      # directory turns out not to be owned by that group we fall back to o+x
      # rather than silently lock the consumer out of its own secrets.
      # via g(), not a bare incus_run: the guest's inherited PATH has no coreutils,
      # so a bare `stat` can fail to resolve and return empty -- and an empty
      # dir_owner reads as "not the group", which would silently fall back to 0711
      # and reopen the Forgejo hole this condition exists to close.
      dir_owner=$(g stat -c '%U' "$dir")
      if [[ $dir_owner == "$group" ]]; then
        dir_mode=0700
      else
        warn "$name:$file -- $dir is owned by '${dir_owner:-unknown}', not $group; falling back to 0711 so the consumer can still traverse it"
      fi
    fi

    current_sum=$(g sha256sum "$path" | awk '{print $1}')
    want_sum=$(printf '%s' "$wanted" | sha256sum | awk '{print $1}')
    cur_mode=$(g stat -c '%a' "$path")
    cur_group=$(g stat -c '%G' "$path")
    cur_dir_mode=$(g stat -c '%a' "$dir")

    # The directory's mode is part of the state this function asserts, not an
    # incidental side effect of the write that happens to set it.
    #
    # Without this check a change to dir_mode can never take effect. The files are
    # already byte-exact, their mode and group already match, every other check
    # passes, and the loop `continue`s past all of them. So the 0711 -> 0700 fix for
    # the Forgejo secret leak would be committed, deployed, reported as done -- and
    # leave the directory at 0711, which is the state that leaks.
    #
    # Not hypothetical: that is exactly what happened on the run which installed it.
    # Content already matched, so nothing was re-rendered, so the directory kept its
    # old mode and `git` could still read secret_key.
    needs_write=0
    [[ -n $current_sum && $current_sum == "$want_sum" ]] || needs_write=1
    [[ $cur_mode == "${mode#0}" ]] || needs_write=1
    if [[ -n $group ]]; then
      [[ $cur_group == "$group" ]] || needs_write=1
    fi
    [[ -n $cur_dir_mode && $cur_dir_mode == "${dir_mode#0}" ]] || needs_write=1
    [[ $needs_write == 0 ]] && continue

    step "rendering $name:$file (mode $mode${group:+, group $group})"
    # mkdir -p the parent first, with the mode stated explicitly.
    #
    # apply.sh cannot assume the directory exists. Caddy happens to have one
    # because a volume is mounted at exactly /var/lib/incus-secrets and Incus
    # creates the mount point for it. A guest cannot: `path` is stripped from a
    # VM's disk devices (a container gets a bind mount, a VM gets a raw block
    # device and mounts it itself), so the wireguard VM has nothing at that path
    # and the first render died with
    #   sh: ... /var/lib/incus-secrets/wireguard-ui-password: No such file or
    #   directory
    # with nothing to say the directory was the missing piece.
    #
    # `chmod` rather than trusting mkdir's default, because mkdir applies the
    # umask and that is only set later in this same chain.
    #
    # 0711, and this is not a detail -- it was 0700 until it took the whole site
    # down. The directory is the *parent* of files whose access control is
    # carried by their own mode and group:
    #
    #   -r--r----- 1 root caddy  /var/lib/incus-secrets/incus-client.crt
    #
    # 0440 group caddy on the file grants the caddy user read, and 0700 root:root
    # on the parent makes that grant unreachable, because the file cannot be
    # reached. Caddy could not read its own client certificate:
    #
    #   loading module 'reverse_proxy': ... loading client certificate key pair:
    #   open /var/lib/incus-secrets/incus-client.crt: permission denied
    #
    # and since caddy serves every hostname on this host, all of them went down.
    #
    # Why it had never fired before: the directory was already 0700 when these
    # secrets were first written, but the render only happens when the content
    # comparison says something changed, and nothing had -- the old string
    # compare called the newline-polluted files correct and skipped every one.
    # The bug sat dormant until that comparison was made byte-exact, the
    # reconciler started doing real work again, and the first render chmod'd the
    # directory out from under a running Caddy.
    # The directory mode depends on who the consumer is, because "traversable by
    # the consumer" has two different meanings across these instances.
    #
    # This was 0700, which broke Caddy: its files are root:caddy, so the *caddy
    # user* has to traverse the directory to reach them, and 0700 root:root denies
    # that regardless of the file's own mode.
    #
    #   loading module 'reverse_proxy': ... loading client certificate key pair:
    #   open /var/lib/incus-secrets/incus-client.crt: permission denied
    #
    # So it became 0711 -- o+x, traverse and nothing more. That fixed Caddy and
    # opened a hole in Forgejo, which is the case this comment now has to explain.
    # Forgejo's secrets are root:forgejo, and `git` is in group forgejo:
    #
    #   uid=1000(git) gid=997(git) groups=997(git),998(forgejo)
    #
    # With o+x on the directory, `git` traverses, and then the files' own 0440
    # group bit grants it read. Measured on the running instance, all six files:
    #
    #   app.ini  internal_token  lfs_jwt_secret
    #   oauth2_jwt_secret  secret_key  smtp_password        -> all READABLE
    #
    # `git` is the identity every SSH session on the host lands as, so this hands
    # SECRET_KEY -- the key whose reuse keeps the admin's TOTP secrets
    # decryptable, and which also signs session cookies -- to anyone who can open
    # a connection.
    #
    # The distinction is ownership, not group: caddy does not own its secrets
    # directory, so it needs o+x; forgejo does own it (User=forgejo, and stat
    # confirms forgejo:forgejo), so 0700 is both sufficient and correct there.
    #
    # PATH is exported because `incus exec -- sh -c` does not get a usable one.
    # The guest inherits /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:
    # /bin, where a NixOS system has no coreutils at all -- ls, head and mkdir
    # are all "command not found". The NixOS profile lives at
    # /run/current-system/sw/bin. Same trap as the missing `logger` in disk.nix:
    # a NixOS exec environment does not carry the PATH a shell script assumes.
    cmd="export PATH=/run/current-system/sw/bin:\$PATH"
    cmd="$cmd && mkdir -p $dir && chmod $dir_mode $dir"
    cmd="$cmd && umask 077 && cat > $path"
    # chgrp before chmod: chown-family calls can clear setuid/setgid bits, and
    # the mode is the thing being asserted here.
    [[ -n $group ]] && cmd="$cmd && chgrp $group $path"
    cmd="$cmd && chmod $mode $path"
    # printf, not a herestring. `<<<` appends a newline, which put a 44th byte
    # on a 43-character SECRET_KEY -- see the digest comparison above for why
    # that went unnoticed and why it is not safe to leave to the consumer's
    # discretion. printf preserves the internal newlines a PEM needs, so
    # format=raw is unaffected apart from no longer gaining a trailing one,
    # which the note on `value=$(<"$source")` already says nothing cares about.
    printf '%s' "$wanted" | incus_run_stdin exec "$name" -- sh -c "$cmd"
    changed=1
  done

  # Only when something actually changed, and only for the units that consume it.
  #
  # reset-failed first, and it is not optional. A unit whose EnvironmentFile is
  # missing does not merely fail once: NixOS's caddy module gives it Restart=, so
  # it retries every few seconds and trips *its own* start rate limit long
  # before we get here. `systemctl restart` then refuses with
  #   Job for caddy.service failed because start of the service was attempted
  #   too often.
  # reset-failed clears that counter, and is a no-op on a healthy unit.
  [[ $changed == 1 ]] || return 0
  mapfile -t consumers < <(jq -r '.secretConsumers[]?' <<<"$spec")
  for unit in ${consumers[@]+"${consumers[@]}"}; do
    step "restarting $unit for the new secret"
    incus_run exec "$name" -- systemctl reset-failed "$unit"
    # Unconditional restart, not try-restart: on a first deploy the unit never
    # started, and try-restart would leave it down.
    incus_run exec "$name" -- systemctl restart "$unit"
  done

  # Did they actually come up?
  #
  # Restarting and returning 0 is not the same as working, and the difference
  # is invisible from here: a consumer that cannot read the file it was just
  # given exits within milliseconds. This script used to report a clean deploy
  # in exactly that situation -- caddy.service was handed a 0400 root-owned PEM
  # and runs as User=caddy, so every hostname went down while apply.sh printed
  # "ok". A restart is a request, not a result, so check the result.
  for unit in ${consumers[@]+"${consumers[@]}"}; do
    state=""
    attempt=0
    # `systemctl restart` is synchronous, so this normally passes first time.
    # The loop is only for units that report readiness a moment after the job.
    while [[ $attempt -lt 10 ]]; do
      state=$(incus_run exec "$name" -- systemctl is-active "$unit" 2>/dev/null || true)
      [[ $state == active ]] && break
      attempt=$((attempt + 1))
      sleep 1
    done
    [[ $state == active ]] && continue

    # Put the reason in the error. Finding this cost a `journalctl` inside the
    # container by hand, and the whole diagnosis is one line of that output.
    warn "$unit is '$state' after rendering $name's secrets; last lines of its log:"
    incus_run exec "$name" -- journalctl -u "$unit" --no-pager -n 12 2>&1 \
      | sed 's/^/      /' >&2 || true
    die "$unit did not come up after rendering $name's secrets (state: ${state:-unknown})." \
        "The instance is running but this consumer is not, so anything depending" \
        "on it -- for caddy, all hostnames -- is down."
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
  local name=$1 spec=$2 kind=$3
  local desired current key device dev_type
  local -a have want

  desired=$(jq -c '.devices // {}' <<<"$spec")
  current=$(instance_json "$name" | jq -c '.devices // {}')

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
    incus_run config device remove "$name" "$key" >/dev/null 2>&1 || true
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
    dev_type=$(jq -r '.type' <<<"$device")
    # `path` is how a *container* sees a disk: Incus bind-mounts the filesystem
    # at that path. A VM gets a raw block device and mounts it in the guest, so
    # it rejects `path` outright. Dropping it here rather than in every spec
    # keeps one device declaration usable by both instance types.
    if [[ $kind == vm && $dev_type == disk ]]; then
      device=$(jq -c 'del(.path)' <<<"$device")
    fi
    # shellcheck disable=SC2046
    incus_run config device add "$name" "$key" "$dev_type" \
      $(jq -r 'to_entries[] | select(.key != "type") | "\(.key)=\(.value)"' <<<"$device")
  done
}

# --------------------------------------------------------------------------
# The host's public entry points
# --------------------------------------------------------------------------
# Incus implements a network forward as an nftables DNAT rule, not a socket
# bind, which is the whole reason this can coexist with the incumbent proxy
# still listening on 0.0.0.0:80. Packets aimed at the listen address are
# rewritten before socket lookup; packets aimed anywhere else on the same port
# are not matched and still reach the old listener. So the cutover is one rule,
# and the rollback is deleting it -- the old listener never stopped holding the
# port.
#
#   rollback:  incus network forward delete <network> <listen address>
#
# Reads here go through `incus network forward list --format json` rather than
# `incus network forward show`, which prints YAML and has no --format flag.
# There is no usable /1.0/network-forwards/<net>/<addr> path either; the list
# is the only route that carries the ports.
#
# One port per entry, always, and the shape the spec declares is the shape this
# converges on. That is not tidiness, it is forced by two Incus behaviours found
# the hard way:
#
#   * `port add ... tcp 80,443 10.0.0.100 80,443` stores ONE entry with
#     listen_port "80,443", not two entries.
#   * `port add` then refuses any listen port an existing entry already claims,
#     grouped or not:
#       Error: Failed updating forward: Duplicate listen port 80 for
#       protocol "tcp" in port specification 1
#
# So a grouped entry cannot be retargeted by adding alongside it, and cannot be
# fixed one port at a time either -- but it CAN be removed by passing its exact
# stored string:
#   incus network forward port remove <net> <listen> tcp "80,443"
#
# Hence remove-then-add against an exact tuple match. Anything not byte-identical
# to a declared entry is removed, then the declared entries are added back one at
# a time. That converges from any starting state -- a hand-made forward, or one
# left over from an older target address -- and once converged it is a no-op.
#
# An earlier version tried to add alongside and only remove entries that carried
# no declared port. Against a grouped entry that meant it skipped the removal,
# tried the add, and died on the duplicate-listen-port error, leaving the forward
# stuck pointing at an address nothing serves.

forward_listing() {
  local network=$1 listing
  listing=$(incus network forward list "$network" --format json 2>/dev/null || echo '[]')
  # An empty listing is not valid input for the filters below.
  [[ -n $listing ]] || listing='[]'
  printf '%s' "$listing"
}

# The port entries of one forward, as a JSON array. Empty array if absent.
forward_ports() {
  local network=$1 listen=$2
  forward_listing "$network" \
    | jq -c --arg l "$listen" '[.[] | select(.listen_address == $l) | .ports[]?]'
}

# "tcp 80 80 10.0.0.100" per declared port. targetPort defaults to listenPort and
# targetAddress to the forward's own target, so the usual case is two bare
# numbers per port.
declared_forwards() {
  local spec=$1 target=$2
  jq -r --arg t "$target" '
    .networkForward.ports[]?
    | select(.protocol != null and (.listenPort != null))
    | "\(.protocol) \(.listenPort) \(.targetPort // .listenPort) \(.targetAddress // $t)"
  ' <<<"$spec"
}

# Every port claimed by ANY instance on this (network, listen address), one
# "proto listen target_port target_addr" per line.
#
# The union, not one instance's own list -- see the call site for why, and for
# the outage this prevents. Deduplicated because two instances may legitimately
# declare the same port to the same target, and `in_list` is exact-match so a
# duplicate would otherwise look like a port to remove and then re-add on every
# run.
#
# Dies rather than returning nothing if the instance specs cannot be read. An
# empty result here means "no instance claims any port", which the removal loop
# would act on by deleting the live forward's ports -- so a read failure has to
# be loud, not an empty list.
forward_declarations() {
  local network=$1 listen=$2 name spec
  local -a names params
  mapfile -t names < <(flake_instances)
  [[ ${#names[@]} -gt 0 ]] || die "cannot read incusInstances; refusing to touch the forward on $network/$listen"

  for name in "${names[@]}"; do
    spec=$(instance_spec "$name") || die "cannot read the spec for instance '$name'"
    mapfile -t params < <(forward_params "$spec")
    # Skip instances with no forward, and ones listening elsewhere: this function
    # is about one address only.
    [[ ${params[1]:-} == "$listen" ]] || continue
    [[ -n ${params[0]:-} && ${params[0]} == "$network" ]] || continue
    declared_forwards "$spec" "${params[2]:-}"
  done | sort -u
}

# The forward's three scalars, ONE PER LINE: the network, the listen address,
# the target. The network comes from the NIC device rather than a constant, so
# renaming the bridge is an edit to one place.
#
# The defaults are `// ""` and never `// empty`. Inside an array constructor
# `empty` does not yield an empty element, it yields *no element*: jq's [] drops
# it and the array comes back short. So a NIC with no network would silently
# shift the listen address into the network slot, the die() meant to catch the
# typo would never fire, and the reconcile would go on to
# `incus network forward create <an-ip> <an-ip>`.
#
# One per line rather than a tab-separated row for the same reason: @tsv also
# drops empty fields.
#
# Read here rather than inline in both callers, so that the reporter and the
# reconciler cannot disagree about what the spec says.
forward_params() {
  jq -r '[
    ([.devices // {} | to_entries[]
      | select(.value.type == "nic") | .value.network // ""][0] // ""),
    (.networkForward.listenAddress // ""),
    (.networkForward.targetAddress // "")
  ] | .[]' <<<"$1"
}

sync_network_forward() {
  local name=$1 spec=$2 network listen target
  local -a params
  mapfile -t params < <(forward_params "$spec")
  network=${params[0]:-}; listen=${params[1]:-}; target=${params[2]:-}

  # An instance that declares no forward gets none. Note this is a no-op and not
  # a removal: dropping `networkForward` from the spec does not take the DNAT
  # away. Repointing or removing a host's public entry points is a deliberate
  # act that should be a one-line incus command someone typed on purpose, not a
  # side effect of editing an instance's spec.
  [[ -n $listen ]] || return 0
  [[ -n $network ]] || die "networkForward is declared but no nic device names a network"
  [[ -n $target ]] || die "networkForward is declared but has no targetAddress"

  # Create the forward before its ports: `port add` needs somewhere to attach.
  if ! forward_listing "$network" \
       | jq -e --arg l "$listen" 'any(.listen_address == $l)' >/dev/null; then
    step "creating network forward $network $listen"
    incus_run network forward create "$network" "$listen"
  fi

  local -a want have

  # Every instance that declares a forward on THIS listen address, not just this
  # one.
  #
  # Incus keys a network forward by (network, listen_address): there is one
  # forward per address and its port list is shared. Caddy holds 80 and 443 on
  # 192.168.178.200; forgejo now wants 22 on the same address. If `want` came
  # from this instance's spec alone, reconciling forgejo would compute
  #
  #   want = [tcp 22 -> 10.0.0.101]
  #   have = [tcp 80 -> 10.0.0.100, tcp 443 -> 10.0.0.100]
  #
  # and the removal loop below would take Caddy's ports off the public site --
  # every hostname 404, on the next unattended reconcile. Verified by running
  # these functions against the live forward and both real specs:
  #
  #   WOULD REMOVE: tcp 80 80 10.0.0.100 tcp 443 443 10.0.0.100
  #   WOULD ADD:    tcp 22 22 10.0.0.101
  #
  # So the port list is the union across every instance, and only a port that no
  # instance claims any more is removed. `forward_declarations` reads every
  # instance spec; if that cannot be read it dies rather than guessing, because
  # guessing here means deleting someone else's public entry point.
  # NOT `mapfile -t want < <(forward_declarations "$network" "$listen")`.
  #
  # A process substitution runs the function in a *subshell*, so the die() inside
  # forward_declarations exits only that subshell. mapfile then reads no output,
  # succeeds anyway, and `want` comes back EMPTY -- and the removal loop above,
  # which runs first by design, takes every port off the forward. That is the
  # outage this whole function exists to prevent, reached *through* the guard that
  # was supposed to prevent it.
  #
  # Found by incus/apply-forward-test.sh test 6, which points the registry stub
  # at nothing and watches it happen. Reading the code had shown the die(); only
  # running it showed that the die() did nothing.
  #
  # Command substitution keeps the status where die() can act on it.
  local declarations
  declarations=$(forward_declarations "$network" "$listen") \
    || die "cannot read the declared forwards on $network/$listen; removing nothing"
  want=()
  [[ -z $declarations ]] || mapfile -t want <<<"$declarations"

  # An empty union while ports exist is a contradiction, not a state to act on:
  # this instance declares a forward on this very address, so its own port is
  # necessarily in the union. An empty one therefore means the registry says
  # something the forward disagrees with, and the removal loop would delete a
  # live public endpoint on the strength of nothing at all.
  if [[ ${#want[@]} -eq 0 ]]; then
    die "no instance declares any port on $network/$listen, yet ports exist; refusing to remove them"
  fi

  # Removal first, so that a port claimed by a stale entry is free to be re-added
  # with the right target. Removal keys on the stored listen_port verbatim:
  # "80,443" is one entry, and taking "80" out of it is not something the CLI
  # can do.
  local ports entry proto listen_port target_port target_addr
  ports=$(forward_ports "$network" "$listen")
  mapfile -t have < <(jq -r '.[] | "\(.protocol) \(.listen_port) \(.target_port) \(.target_address)"' \
                     <<<"$ports")

  for entry in ${have[@]+"${have[@]}"}; do
    if in_list "$entry" "${want[@]+"${want[@]}"}"; then
      continue
    fi
    read -r proto listen_port _ _ <<<"$entry"
    step "removing forward $listen/$proto/$listen_port (not as declared)"
    incus_run network forward port remove "$network" "$listen" "$proto" "$listen_port"
  done

  # Then add. Re-read ports: the removals above changed it, and `have` is now
  # stale for anything that was removed.
  ports=$(forward_ports "$network" "$listen")
  mapfile -t have < <(jq -r '.[] | "\(.protocol) \(.listen_port) \(.target_port) \(.target_address)"' \
                     <<<"$ports")

  for entry in ${want[@]+"${want[@]}"}; do
    if in_list "$entry" "${have[@]+"${have[@]}"}"; then
      continue
    fi
    read -r proto listen_port target_port target_addr <<<"$entry"
    step "forwarding $listen/$proto/$listen_port -> $target_addr/$target_port"
    incus_run network forward port add "$network" "$listen" \
      "$proto" "$listen_port" "$target_addr" "$target_port"
  done
}


# --------------------------------------------------------------------------
# Incus client-certificate trust
# --------------------------------------------------------------------------
# Incus decides whether to accept a client by looking up the *fingerprint* of the
# certificate it was presented, not by checking who signed it. So a self-signed
# client certificate works, which is what lets an instance authenticate to the
# API without ever holding the server's CA key.
#
# Compared by certificate content rather than fingerprint, because computing a
# fingerprint needs openssl and openssl is not in the system PATH -- the reconciler
# gets `/run/current-system/sw/bin` and nothing else. Reading the certificate back
# out of the trust store avoids the dependency entirely.
sync_incus_trust() {
  local name=$1 spec=$2 trust_name source want_norm fingerprint
  local -a stale

  trust_name=$(jq -r '.incusTrust.name // empty' <<<"$spec")
  [[ -n $trust_name ]] || return 0

  source=$(jq -r '.incusTrust.certificate // empty' <<<"$spec")
  [[ -n $source ]] || die "$name declares incusTrust but names no certificate"
  assert_secret_readable "$source" "$name's client certificate"

  want_norm=$(tr -d '[:space:]' <"$source")

  # Trusted already, under any name. Comparing across all entries rather than
  # just this one means a certificate that was added by hand under a different
  # name does not get a second, redundant entry.
  if incus config trust list --format json \
       | jq -e --arg c "$want_norm" 'any(.certificate | gsub("\\s"; "") == $c)' \
       >/dev/null; then
    return 0
  fi

  [[ $EUID -eq 0 ]] || die "$name declares incusTrust but apply.sh is not root"

  # A same-named entry holding something else means the certificate was rotated.
  # Remove by fingerprint, not by name: `incus config trust remove <name>` reports
  # "Certificate not found" and removes nothing.
  mapfile -t stale < <(incus config trust list --format json \
    | jq -r --arg n "$trust_name" '.[] | select(.name == $n) | .fingerprint')

  for fingerprint in ${stale[@]+"${stale[@]}"}; do
    warn "trust entry '$trust_name' holds a different certificate (${fingerprint:0:12}); replacing it"
    incus_run config trust remove "$fingerprint"
  done

  step "trusting $name's client certificate as '$trust_name'"
  incus_run config trust add-certificate --name "$trust_name" \
    --description "$name: authenticates to the Incus API from its Caddy vhost" \
    "$source"
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

# The inet addresses of the interface behind the eth0 device.
#
# NOT `.state.network.eth0`. That map is keyed by the interface name the GUEST's
# kernel uses, and a VM's kernel renames eth0. Measured on this host:
#
#   caddy          (container)  eth0, lo
#   wireguard      (vm)         enp5s0, enp6s0, lo, wg0
#   forgejo-runner (vm)         docker0, enp5s0, lo
#
# so the literal key matched for containers and for no VM at all. Every lookup
# for a VM returned empty, which meant three things, none of them visible from
# the exit status:
#
#   * wait_ready spun its entire 60-iteration budget and then warned
#     "forgejo-runner had no address on eth0 after 60s (status: Running)" on
#     every single VM start, for an instance that had its address about 15s in.
#   * the closing summary printed "ok -- Running" with no address in it, which
#     is how a container reads and how a VM read.
#   * wait_ready never actually confirmed that a VM had an address. A VM that
#     booted unrouted -- exactly what the pinned hwaddr in incus.nix exists to
#     rule out -- passed apply with nothing but that warning, and a warning
#     printed on every start is a warning nobody reads.
#
# So resolve the interface rather than assuming the two names agree, and join on
# the device's MAC, which every VM pins (it has to: an Incus-assigned MAC
# changes on a re-create). A container with no pinned MAC has no `hwaddr` on the
# device at all -- not under `devices`, not under `expanded_devices`, because
# Incus only surfaces the MAC it generated in `state.network` -- so those fall
# back to matching by NAME, which is right for a container because its veth
# really is called eth0: a container shares the host kernel and does not rename
# anything.
#
# The fallback has to stay a name comparison. Comparing an absent MAC against ""
# matches `lo`, whose hwaddr is also empty, and reports 127.0.0.1 as the
# instance's address.
#
# For wireguard this returns 192.168.178.210, the macvlan address: its eth0 is a
# macvlan on eno1 and the incusbr0 address (10.0.0.110) is on eth1. That is the
# right answer for both callers, which want to know the instance came up on the
# network, not which network that was.
instance_address() {
  # One call, one jq. The address list is joined INSIDE the filter: piping this
  # jq's raw text output into a second `jq -s` makes it try to parse
  # `10.0.0.102` as a JSON number, and every lookup fails with
  # "Invalid numeric literal".
  incus_run list "$1" --format json \
    | jq -r '
        [ .[0] as $inst
          | (($inst.expanded_devices.eth0.hwaddr) // "") as $mac
          | (($inst.state.network) // {})
          | to_entries[]
          | select(if $mac == "" then .key == "eth0"
                   else (.value.hwaddr // "") == $mac end)
          | (.value.addresses // [])[]?
          | select(.family == "inet")
          | .address ]
        | join(",")
      '
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
  local network listen target port
  local -a params ports_declared
  alias="$IMAGE_PREFIX/$name"
  log "no instance named $name -- would create it from $alias"
  log "  image build output: $(store_name "$build_path")"
  log "  volumes: $(jq -r '[.volumes[]? | "\(.pool)/\(.name)"] | join(", ")' <<<"$spec")"
  log "  devices: $(jq -r '[.devices | keys[]] | join(", ")' <<<"$spec")"
  mapfile -t params < <(forward_params "$spec")
  network=${params[0]:-}; listen=${params[1]:-}; target=${params[2]:-}
  if [[ -n $listen ]]; then
    log "  network forward: would point $listen on bridge $network at $target, so this"
    log "    instance becomes what the outside world reaches the host on"
    mapfile -t ports_declared < <(declared_forwards "$spec" "$target")
    for port in ${ports_declared[@]+"${ports_declared[@]}"}; do
      log "    $port"
    done
  fi
}

report_existing_drift() {
  local name=$1 spec=$2 build_path=$3 old_fingerprint=$4
  local key value current want_dev cur_dev device alias recorded
  local trust_name trust_source want_norm fingerprint
  local -a want_keys stale_trust

  alias="$IMAGE_PREFIX/$name"
  # incus_run, for the same reason as the flake-rev read above: a bare `incus`
  # here reports the alias in `default`, so `recorded` came back empty for a
  # project-scoped instance. Empty is not neutral in the branch below -- it is
  # the "no image at alias yet" case, which makes every run report the instance
  # as having no image and skip the "build inputs unchanged" short-circuit.
  recorded=$(incus_run image get-property "$alias" user.build-source 2>/dev/null || true)

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

  # Reported next to limits because it is the same kind of thing -- a number
  # the instance is given rather than a cap it must stay under -- and it is
  # the one that cannot be walked back once applied.
  want_root=$(jq -r '.rootDiskSize // empty' <<<"$spec")
  have_root=$(instance_field "$name" '.devices.root.size // empty')
  if [[ -n $want_root && $want_root != "$have_root" ]]; then
    log "  root disk size: have '${have_root:-Incus default}' want '$want_root' (grow only; the guest needs a restart to claim it)"
  fi

  cur_dev=$(instance_json "$name" | jq -c '.devices // {}')
  want_dev=$(jq -c '.devices // {}' <<<"$spec")
  # mapfile then for, for the same reason as sync_devices.
  mapfile -t want_keys < <(jq -r 'keys[]' <<<"$want_dev")
  for key in ${want_keys[@]+"${want_keys[@]}"}; do
    device=$(jq -c --arg k "$key" '.[$k]' <<<"$want_dev")
    if ! device_matches "$(jq -c --arg k "$key" '.[$k] // {}' <<<"$cur_dev")" "$device"; then
      log "  device $key: have $(jq -c --arg k "$key" '.[$k] // {}' <<<"$cur_dev") want $device"
    fi
  done

  # The DNAT. Reported here even though it is applied last, because in --check
  # nothing is applied at all and this is the one change that carries traffic.
  #
  # Same exact-tuple comparison as sync_network_forward, deliberately. A reporter
  # with its own idea of what counts as a match will disagree with the thing it
  # is reporting on -- which is how the first version of this ended up printing
  # drift on a forward that was, by the reconciler's own definition, correct.
  local network listen target ports entry declarations
  local -a params
  mapfile -t params < <(forward_params "$spec")
  network=${params[0]:-}; listen=${params[1]:-}; target=${params[2]:-}
  if [[ -n $listen && -n $network ]]; then
    local -a want have
    # The UNION across instances, the same one sync_network_forward reconciles
    # against -- NOT this instance's own declared_forwards.
    #
    # The reporter is the last thing standing between a mistake here and the
    # fifteen-minute timer, so it has to agree with the reconciler exactly. With
    # one instance's list, reconciling forgejo printed:
    #
    #   forward 192.168.178.200/tcp 22 22 10.0.0.101 (want)
    #   forward 192.168.178.200/tcp 80 80 10.0.0.100 (have, not declared)
    #   forward 192.168.178.200/tcp 443 443 10.0.0.100 (have, not declared)
    #
    # i.e. it announced the removal of Caddy's public entry points on every run,
    # on a forward that is entirely correct. A --check that cries wolf about the
    # one change that carries all the traffic is a --check that gets ignored --
    # and the run where it is right is the run nobody reads any more.
    #
    # Captured with command substitution rather than mapfile < <(...) for the same
    # reason as in sync_network_forward: a die() in a process substitution exits
    # only the subshell, and here that would silently degrade to "this instance
    # declares nothing" -- which prints exactly the false removals above.
    declarations=$(forward_declarations "$network" "$listen") \
      || die "cannot read the declared forwards on $network/$listen"
    want=()
    [[ -z $declarations ]] || mapfile -t want <<<"$declarations"
    ports=$(forward_ports "$network" "$listen")
    mapfile -t have < <(jq -r '.[] | "\(.protocol) \(.listen_port) \(.target_port) \(.target_address)"' \
                       <<<"$ports")
    for entry in ${want[@]+"${want[@]}"}; do
      if ! in_list "$entry" "${have[@]+"${have[@]}"}"; then
        log "  forward $listen/$entry (want)"
      fi
    done
    for entry in ${have[@]+"${have[@]}"}; do
      if ! in_list "$entry" "${want[@]+"${want[@]}"}"; then
        log "  forward $listen/$entry (have, not declared)"
      fi
    done
  elif [[ -n $listen ]]; then
    log "  networkForward declared but no nic device names a network"
  fi

  # Client-certificate trust. Compared the same way sync_incus_trust compares it,
  # so that this cannot report drift against a state the reconcile considers
  # settled.
  local trust_name trust_source want_norm
  trust_name=$(jq -r '.incusTrust.name // empty' <<<"$spec")
  if [[ -n $trust_name ]]; then
    trust_source=$(jq -r '.incusTrust.certificate // empty' <<<"$spec")
    if [[ ! -r $trust_source ]]; then
      log "  incusTrust '$trust_name': $trust_source is not readable"
    else
      want_norm=$(tr -d '[:space:]' <"$trust_source")
      if ! incus config trust list --format json \
           | jq -e --arg c "$want_norm" 'any(.certificate | gsub("\\s"; "") == $c)' \
           >/dev/null; then
        log "  incusTrust '$trust_name': this certificate is not trusted yet"
      fi
      mapfile -t stale_trust < <(incus config trust list --format json \
        | jq -r --arg n "$trust_name" --arg c "$want_norm" \
            '.[] | select(.name == $n and (.certificate | gsub("\\s"; "") != $c)) | .fingerprint')
      for fingerprint in ${stale_trust[@]+"${stale_trust[@]}"}; do
        log "  incusTrust '$trust_name': entry ${fingerprint:0:12} holds a different certificate"
      done
    fi
  fi
}

# --------------------------------------------------------------------------
# The reconcile
# --------------------------------------------------------------------------
apply_instance() {
  local name=$1
  local spec alias fingerprint rev build_output kind
  local existed=0 want_running=1 old_fingerprint=""
  local rootfs metadata unit
  local -a artifacts

  TAG="$name"
  # Before anything that could need the project to exist: an image import, a
  # volume, or an instance create all fail with an error that names neither the
  # project nor the missing prerequisite.
  ensure_project
  spec=$(instance_spec "$name")
  alias="$IMAGE_PREFIX/$name"
  # `type` is the Incus instance type. It changes the shape of the build, not
  # just the device set: a container image is a rootfs plus a metadata tarball,
  # a VM image is a single qcow2. Defaulting to container keeps every existing
  # spec working unchanged.
  kind=$(jq -r '.type // "container"' <<<"$spec")
  case $kind in
    container|vm) ;;
    *) die "$name has type '$kind' (want container or vm)" ;;
  esac
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
  if ! build_output=$(build_artifacts "$name" "$kind"); then
    die "could not build the $name image (see the build output above)"
  fi
  mapfile -t artifacts <<<"$build_output"

  # Two for both kinds: the rootfs (a squashfs, or a qcow2 for a VM) plus the
  # metadata tarball. `kind` chose where the rootfs came from; it does not change
  # how many artefacts there are.
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

  ensure_volumes "$name" "$spec" "$kind"

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
    # `--vm`, a boolean flag, NOT `-t virtual-machine`.
    #
    # `-t/--type` on `incus create` selects a *resource-limit preset* -- c2, m4,
    # and so on -- not the container/VM distinction. Its help text reads
    # "Instance type", which is exactly the wrong name to be guessing from. The
    # server validates the value by splitting on "-" and requiring each field to
    # start with 'c' or 'm', so both spellings fail identically:
    #   Error: Provided instance type doesn't exist: vm
    #   Error: Provided instance type doesn't exist: virtual-machine
    #
    # Explicit rather than relying on Incus inferring the type from the image.
    # Inference would work -- the imported image is typed virtual-machine -- but
    # "probably" is not a good property for the flag that decides whether this is
    # a container or a VM.
    if [[ $kind == vm ]]; then
      incus_run create "$fingerprint" "$name" -p default --vm
    else
      incus_run create "$fingerprint" "$name" -p default
    fi
  fi

  # Incus's own boot.autostart, reconciled from the same spec field.
  #
  # A different setting from the `autostart` handled above, and easy to miss
  # because they share a name. The one further up decides only what this script
  # does *right now*: start the instance, or leave it stopped after a reconcile.
  # It has no effect on what happens at host boot. That is `boot.autostart` on
  # the instance, and Incus defaults it to false.
  #
  # So every instance reconciled correctly and still failed to come up after a
  # host reboot: all three had boot.autostart unset, and the string
  # "boot.autostart" appeared nowhere in this script. What masked it is the
  # incus-apply-<name>.path units -- enabled, and firing on every change under
  # the repo, so a host being edited continuously kept reconciling instances by
  # accident. A plain reboot with a clean tree fires nothing, and caddy, forgejo
  # and the VPN all stay down.
  #
  # One field, one meaning: `autostart = true` in a spec now means both "start it
  # on apply" and "start it on boot", so there is no second list to drift.
  # `autostart = false` still only governs the apply-time start, deliberately: a
  # service stopped on purpose should not also become unbootable.
  #
  # Compared as a string against the literal "true", not via jq's // operator.
  # // treats false as empty and would report every instance as needing a change,
  # turning this into a step that does the same thing on every run.
  reconcile_boot_autostart "$name" "$spec"

  set_description "$name" "$spec"
  apply_limits "$name" "$spec"
  apply_root_disk_size "$name" "$spec" "$kind"
  sync_devices "$name" "$spec" "$kind"

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

  # After render_secrets, so the certificate it trusts is the one that was just
  # validated and written. This is the only global Incus state apply.sh touches --
  # everything else is per-instance -- so it is kept to a single, additive entry.
  sync_incus_trust "$name" "$spec"

  # And the reverse of that: remove this instance's alias from every project it
  # does NOT live in. Runs here because this is the first point at which the
  # instance is known healthy, and because an alias left in the WRONG project is
  # invisible from inside the right one -- the reconcile of `forgejo` only ever
  # looks in `forgejo`, which is exactly why a stale one survived every run.
  #
  # See drop_foreign_aliases for the measurement: a 324 MB image the weekly GC
  # could not collect, held by an alias that nothing owned.
  drop_foreign_aliases "$IMAGE_PREFIX/$name" "$PROJECT"

  # LAST, after the instance is up and its consumers have been restarted. This
  # is the DNAT that makes the instance reachable from outside, so pointing it at
  # anything but a running, serving container is the one way this script could
  # take traffic down rather than hand it over. Earlier in the function is
  # strictly worse: a recreate leaves the instance down for seconds, and a
  # fresh create has not run its software yet.
  if [[ $want_running == 1 ]]; then
    sync_network_forward "$name" "$spec"
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
    --project)  PROJECT_OVERRIDE="${2:?--project needs a value}"; shift ;;
    --project=*) PROJECT_OVERRIDE="${1#--project=}" ;;
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
  # Set PROJECT per instance rather than once for the run. --all spans projects
  # -- incus-reconcile.timer runs it every fifteen minutes precisely so nothing
  # waits on a human -- and one global value would reconcile every instance in
  # the *last* one's project, which for a two-project set means the other is
  # reported missing and recreated as a duplicate on every sweep.
  PROJECT="$(instance_project "$name")"
  apply_instance "$name"
done

TAG="apply"
log "done"
