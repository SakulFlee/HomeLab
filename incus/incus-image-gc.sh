#!/usr/bin/env bash
#
# incus/incus-image-gc.sh -- delete Incus images this reconciler left behind.
#
# incus/apply.sh never deletes an image, which is the right call inside a
# reconcile. But its comment used to say old images are "left for Incus's own
# GC", and that is not true on this deployment. Measured, not assumed:
#
#   * 20 unaliased, reconciler-built images sat in the `default` project and 14
#     more in `forgejo`.
#   * 16 of them are from a nixpkgs pin from July. They are weeks old.
#   * `incus query /1.0/images/<fp>` reports `"used_by": null` on them, so they
#     are genuinely unreferenced, not quietly pinned by a VM.
#   * `images.auto_prune` is unset, and nothing has ever been pruned.
#
# So the pool only grows. This is the other half of apply.sh's contract.
#
# Usage:
#   incus/incus-image-gc.sh [--dry-run]
#
# Options:
#   --dry-run   Report what would be deleted. Touches nothing: no delete, and no
#               state file written, so a dry run cannot make a real image eligible
#               by recording it as "seen".
#
# Environment:
#   INCUS_IMAGE_GC_STATE_DIR   where per-project state lives  (default /var/lib/incus)
#   INCUS_IMAGE_GC_PROJECTS    projects to consider, space separated.
#                              (default: every project Incus knows)
#
# What is eligible
# ----------------
# An image is deleted only if all three hold:
#
#   1. it carries `user.build-source`. That property is written by apply.sh and
#      by nothing else, so it is the discriminator between images this repository
#      built and images a human imported. Measured on this pool: the Ubuntu and
#      OpenSUSE images carry no build-source and are therefore never candidates,
#      with no special-casing for them.
#   2. no alias names it. The alias is what apply.sh moves to point at the current
#      build, so an aliased image is the one something is running from.
#   3. it was ALSO unreferenced at the previous run. See below.
#
# Why it takes two observations
# -----------------------------
# The obvious design -- delete everything unreferenced right now -- has no
# retention window at all, and it fails in a way that is easy to miss. An image
# becomes unreferenced the moment apply.sh moves an alias off it, which is
# minutes or hours after it was built. A weekly GC that ran six days later would
# delete the image you are one bad deploy away from rolling back to, and would do
# so without ever having printed a suspicious-looking number.
#
# The cadence does not fix this on its own. "Unreferenced when the timer last
# fired" is NOT "unreferenced for a week", because the image can become
# unreferenced the day *after* that run. Retention has to be measured by
# observation, not by the interval between runs:
#
#   run N   compute unreferenced set, delete only what was in run N-1's set,
#           write the current set
#   run N+1 same
#
# An image therefore survives one full interval unreferenced before it can be
# deleted, so a weekly timer gives roughly one to two weeks of rollback. That is
# the whole reason this file keeps state, and it is also why it is safe to run
# against a pool the reconciler is actively moving aliases around in.
#
# Never --force
# -------------
# Incus is the authority on whether an image is still referenced, and it refuses
# to delete one that is. So every delete here is attempted without --force and a
# refusal is reported as "in use, skipped" rather than treated as a failure.
# --force appears nowhere in this file, and a test asserts that: it is the one
# thing in here that could delete a running instance's image on a future Incus
# that tracks references differently than this one does.

set -uo pipefail

export PATH="/run/current-system/sw/bin:$PATH"

STATE_DIR="${INCUS_IMAGE_GC_STATE_DIR:-/var/lib/incus}"
DRY_RUN=0

log() { printf '%s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      log "gc  unknown option: $1"
      exit 2
      ;;
  esac
done

if ! command -v incus >/dev/null 2>&1; then
  log "gc  incus is not on PATH; nothing to do"
  exit 1
fi

# Only create the state directory when we are actually going to write. A dry run
# that made a directory was still a dry run that touched something.
if [[ $DRY_RUN -eq 0 ]]; then
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    log "gc  FATAL: cannot create $STATE_DIR; refusing to run blind"
    log "gc  Without state every image would look like a first observation and"
    log "gc  nothing would ever be deleted -- silently."
    exit 1
  fi
fi

projects=()
if [[ -n "${INCUS_IMAGE_GC_PROJECTS:-}" ]]; then
  # shellcheck disable=SC2206  # deliberate word splitting: this is a list
  projects=(${INCUS_IMAGE_GC_PROJECTS})
else
  # JSON, not CSV, and the reason is specific rather than aesthetic.
  #
  # `incus project list --format csv` does not emit CSV with a header row. It
  # emits the TABLE format through a csv serialiser, so the first line IS the
  # header and the current project comes back decorated:
  #
  #   default (current),YES,YES,YES,YES,YES,YES,Default Incus project,32
  #   forgejo,YES,NO,YES,YES,NO,NO,"HomeLab Forgejo (...)
  #
  # Measured on the host. Two separate mistakes follow from that. `cut -d, -f1`
  # yields "default (current)" -- a project that does not exist -- and the
  # header is indistinguishable from data, so there is no header to skip. The
  # result was a GC that reported success having considered a project named
  # "default (current)", never considered `default` at all, and so collected 13
  # of the 33 unreferenced images it was supposed to.
  #
  # JSON has neither problem: there is no header row to mistake for data, and
  # `.name` is the name. `--format yaml` works too, but jq is already in this
  # unit's path and the rest of the script is jq; a YAML parser would be a new
  # dependency to read one field.
  #
  # Verified on the live host before changing this, not assumed:
  #   csv:  <default (current)
  #   json: <default
  #
  # jq, and not `incus project list --format csv | grep -v ,`, because a
  # legitimate project name could contain a comma and be filtered by accident.
  # (The forgejo description already contains one, in a quoted CSV field.)
  project_json=$(incus project list --format json 2>/dev/null)
  if [[ -z $project_json ]] || ! jq -e . >/dev/null 2>&1 <<<"$project_json"; then
    log "gc  FATAL: could not list projects. Refusing to run."
    log "gc  An empty project list is indistinguishable from 'nothing to collect',"
    log "gc  and this script would then report success while collecting nothing."
    exit 1
  fi
  while read -r p; do
    [[ -n $p ]] && projects+=("$p")
  done < <(jq -r '.[].name' <<<"$project_json")
fi

if [[ ${#projects[@]} -eq 0 ]]; then
  log "gc  no projects to consider; is incus running?"
  exit 1
fi

# The fingerprints this project has left behind, one per line, taken from JSON
# already on hand rather than from a second `incus image list`.
#
# jq does the selection so the rule lives in one readable place: ours (has a
# build-source) AND unaliased (no alias names it). `aliases` is absent rather than
# empty on some Incus versions, hence the `?`.
#
# Taking the JSON as an argument rather than re-listing is not only cheaper. Two
# calls can disagree -- an image imported or aliased in between -- and then the
# state file would record a fingerprint this run never considered, which is the
# one way to manufacture a false "seen twice".
unreferenced_now() {
  jq -r '
    .[]
    | select((.properties["user.build-source"] // "") != "")
    | select((.aliases | length) == 0)
    | .fingerprint
  ' <<<"$1"
}

total_unref=0
total_cand=0
total_deleted=0
total_skipped=0
# Names, not just a count. A GC that cannot see a project should say which, and
# "1 unreadable project" sends the reader looking rather than telling them.
unreadable_projects=()

for project in "${projects[@]}"; do
  state="$STATE_DIR/image-gc-$project"

  # An unreadable project is fatal for the whole run, not a skip.
  #
  # This was "log and continue", and the reason that is wrong is arithmetic: the
  # dry run on the host reported
  #
  #   gc  default (current): FATAL: cannot list images; skipping this project
  #   gc  forgejo: 13 unreferenced of ours, 0 seen twice, 0 deleted
  #   gc  dry run: 13 unreferenced, 0 seen twice, 0 would be deleted
  #   exit: 0
  #
  # `default` holds 20 of the 33 unreferenced images, so the run collected 13 and
  # exited 0 -- a clean pass over a pool it had not actually looked at. A
  # garbage collector that cannot see the project holding most of its targets must
  # not report success, so this counts as a failure and every project is still
  # attempted: one unreadable project should not hide the ones that are readable.
  if ! images_json=$(incus image list --project "$project" --format json 2>/dev/null); then
    log "gc  $project: FATAL: cannot list images"
    unreadable_projects+=("$project")
    continue
  fi
  if [[ -z $images_json ]] || ! jq -e . >/dev/null 2>&1 <<<"$images_json"; then
    log "gc  $project: FATAL: image list did not return JSON"
    unreadable_projects+=("$project")
    continue
  fi

  now=$(unreferenced_now "$images_json")
  n_now=0
  [[ -n $now ]] && n_now=$(grep -c . <<<"$now")

  # First run has no previous set, so nothing is a candidate. That is correct and
  # it is why the very first GC after deploying this deletes nothing: it has not
  # yet seen anything twice.
  prev=""
  if [[ -f $state ]]; then
    prev=$(grep -E '^[0-9a-f]+$' "$state" 2>/dev/null || true)
  fi

  candidates=""
  if [[ -n $now && -n $prev ]]; then
    candidates=$(grep -xF -f <(grep -E '^[0-9a-f]+$' <<<"$prev") <<<"$now" 2>/dev/null || true)
  fi
  n_cand=0
  [[ -n $candidates ]] && n_cand=$(grep -c . <<<"$candidates")

  deleted=0
  skipped=0
  if [[ -n $candidates ]]; then
    while read -r fp; do
      [[ -n $fp ]] || continue
      if [[ $DRY_RUN -eq 1 ]]; then
        log "gc  $project: would delete ${fp:0:12} (unreferenced at the last two runs)"
        deleted=$((deleted + 1))
        continue
      fi
      if incus image delete --project "$project" "$fp" >/dev/null 2>&1; then
        log "gc  $project: deleted ${fp:0:12}"
        deleted=$((deleted + 1))
      else
        # Almost always "still in use". Not fatal and not worth failing a
        # garbage collection over; the image stays in the state file and is
        # retried next time.
        log "gc  $project: skipped ${fp:0:12} -- Incus refused, so it is in use"
        skipped=$((skipped + 1))
      fi
    done <<<"$candidates"
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    # Write the FULL current unreferenced set, not the remainder. Anything we
    # deleted simply is not listed next run, so the file prunes itself; anything
    # we failed to delete stays and is retried. Keeping it to the remainder
    # instead would silently forgive an image Incus refused, and it would never
    # be offered again.
    if [[ -n $now ]]; then
      printf '%s\n' "$now" >"$state"
    else
      : >"$state"
    fi
  fi

  log "gc  $project: $n_now unreferenced of ours, $n_cand seen twice, $deleted deleted, $skipped skipped"
  total_unref=$((total_unref + n_now))
  total_cand=$((total_cand + n_cand))
  total_deleted=$((total_deleted + deleted))
  total_skipped=$((total_skipped + skipped))
done

if [[ $DRY_RUN -eq 1 ]]; then
  log "gc  dry run: $total_unref unreferenced, $total_cand seen twice, $total_deleted would be deleted, $total_skipped skipped"
  log "gc  no state written, so nothing became eligible by being looked at"
else
  log "gc  done: $total_unref unreferenced, $total_cand seen twice, $total_deleted deleted, $total_skipped skipped"
fi

# Non-zero when any project's images could not be read at all. A delete that Incus
# refused is not an error here, and neither is finding nothing to do.
if [[ ${#unreadable_projects[@]} -gt 0 ]]; then
  log "gc  FAILED: ${#unreadable_projects[@]} project(s) could not be read: ${unreadable_projects[*]}"
  log "gc  The counts above are what was visible, not the whole pool. Treating this"
  log "gc  as success is how 33 unreferenced images were reported as 13."
  exit 1
fi
exit 0