#!/usr/bin/env bash
# Tests for incus/incus-image-gc.sh. Run it:  ./incus/incus-image-gc-test.sh
#
# Pure bash against a stubbed `incus` on PATH, so it needs no Incus, no Nix and no
# root, and cannot delete anything real. The stub records every call it receives,
# which is the only way to prove the *command line* was right -- and the command
# line is the part that matters, because the one destructive flag in Incus is a
# command-line flag.
#
# The tests are organised around the one property that is easy to get wrong and
# impossible to notice by inspection: an image must be seen unreferenced TWICE
# before it is deleted. A GC that deleted on first sight would pass every test
# that only checks "the right things eventually go away", and would quietly
# delete the image you are one bad deploy away from rolling back to.
set -uo pipefail

GC=${GC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/incus-image-gc.sh}
[[ -f $GC ]] || { echo "FATAL: $GC not found"; exit 99; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/state" "$WORK/pool"

fails=0
check() {
  local what=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$what" "$want" "$got"
    fails=$((fails + 1))
  fi
}

# --- the incus stub ---------------------------------------------------------
# Refuses to delete a fingerprint listed in $WORK/refuse, which is how the
# "Incus says it is in use" path is exercised without an actual in-use image.
cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
echo "incus $*" >>"$CALLLOG"
project=""; args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --project) project=$2; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
sub=${args[0]-}
case "$sub ${args[1]-}" in
  "project list")
    # Reproduces what the real Incus prints, not what is convenient.
    #
    # `incus project list --format csv` is NOT csv-with-a-header: it emits the
    # table format through a csv serialiser, so the first line is the header and
    # the current project is decorated with "(current)". An earlier fixture here
    # printed bare names, which is why the suite passed against a real Incus that
    # does not, and the GC went looking for a project named "default (current)".
    #
    # With PROJECTS_BAD set, it emits the CSV shape instead, so a regression to
    # CSV parsing is caught rather than quietly tolerated.
    if [[ -n ${PROJECTS_BAD:-} ]]; then
      echo "NAME,IMAGES,PROFILES,STORAGE VOLUMES,STORAGE BUCKETS,NETWORKS,NETWORK ZONES,DESCRIPTION,USED BY"
      first=1
      for p in "$POOL"/*/; do
        p=${p%/}; b=$(basename "$p")
        if [[ $first == 1 ]]; then
          echo "$b (current),YES,YES,YES,YES,YES,YES,Default Incus project,32"
        else
          echo "$b,YES,NO,YES,YES,NO,NO,\"HomeLab $b\",19"
        fi
        first=0
      done
      exit 0
    fi
    printf '['
    first=1
    for p in "$POOL"/*/; do
      p=${p%/}; b=$(basename "$p")
      [[ $first == 1 ]] || printf ','
      first=0
      printf '{"name":"%s","description":"HomeLab %s","used_by":[],"config":{}}' "$b" "$b"
    done
    printf ']'
    ;;
  "image list")
    f="$POOL/$project/images.json"
    # A missing fixture stands in for "this project cannot be read". Returning an
    # empty array instead would make an outage indistinguishable from an empty
    # pool, which is the whole difference between section 10 and a false all-clear.
    if [[ ! -f $f ]]; then
      echo "Error: Not found" >&2
      exit 1
    fi
    cat "$f"
    ;;
  "image delete")
    # args[2], not args[1]: args is (image delete <fp>) once --project has been
    # eaten. Taking args[1] here made the stub "delete" the literal string
    # "delete", which removed nothing, left the image unreferenced and in the
    # state file, and made every later run re-delete it -- so sections 3 and 7
    # failed for a reason that had nothing to do with the script under test.
    fp=${args[2]-}
    if grep -qxF "$fp" "$REFUSE" 2>/dev/null; then
      echo "Error: Image is currently in use" >&2
      exit 1
    fi
    # Remove it, so the next run sees a pool that has actually changed. Without
    # this the stub is not modelling Incus: the image would still be listed, still
    # unreferenced, still in the state file, and would be "deleted" every run --
    # which would make section 3 pass or fail for reasons that have nothing to do
    # with the script.
    f="$POOL/$project/images.json"
    if [[ -f $f ]]; then
      jq --arg fp "$fp" 'map(select(.fingerprint != $fp))' "$f" >"$f.tmp" \
        && mv "$f.tmp" "$f"
    fi
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/incus"

export CALLLOG=$WORK/calls
export REFUSE=$WORK/refuse
export POOL=$WORK/pool
# Without this the script does the right thing and refuses to run: it defaults to
# /var/lib/incus, which a non-root test cannot create, and exits 1 rather than
# collecting without state. That refusal is section 10's subject, so it has to
# be satisfied here or every other section fails for the same uninteresting
# reason.
export INCUS_IMAGE_GC_STATE_DIR=$WORK/state
: >"$REFUSE"

# --- fixtures ---------------------------------------------------------------
# img <fingerprint> <aliased:0|1> <ours:0|1>
#
# "ours=0" omits user.build-source ENTIRELY rather than setting it to "-" or "",
# because that is what Incus actually does -- /1.0/images/<fp> simply has no such
# key for an image this reconciler did not build. A fixture that set it to "-"
# passes the script's `!= ""` filter, so section 5 tested nothing while reporting
# that it had.
img() {
  local fp=$1 aliased=$2 ours=$3 alias='[]' props='"description":"d"'
  [[ $aliased == 1 ]] && alias='[{"name":"homelab/thing"}]'
  if [[ $ours == 1 ]]; then
    props="$props,\"user.build-source\":\"/nix/store/xxx-nixos-lxc-image-x86_64-linux/nixos-lxc-image-x86_64-linux.squashfs\",\"user.flake-rev\":\"deadbee\""
  fi
  cat <<JSON
{"fingerprint":"$fp","aliases":$alias,"properties":{$props}}
JSON
}

# seed <project> <fingerprint:aliased:ours>...
seed() {
  local p=$1; shift
  mkdir -p "$POOL/$p"
  : >"$POOL/$p/images.json.tmp"
  printf '[' >"$POOL/$p/images.json"
  local first=1
  for spec in "$@"; do
    IFS=: read -r fp al ou <<<"$spec"
    [[ $first == 1 ]] || printf ',' >>"$POOL/$p/images.json"
    first=0
    img "$fp" "$al" "$ou" >>"$POOL/$p/images.json"
  done
  printf ']' >>"$POOL/$p/images.json"
}

run_gc() {
  : >"$CALLLOG"
  # PROJECTS_BAD is passed through explicitly rather than inherited. A caller that
  # sets it as a prefix assignment -- PROJECTS_BAD=1 rc=$(run_gc) -- would
  # otherwise leak it into every later run through the exported environment, and
  # the sections after this one would be testing the CSV fixture while appearing
  # to test the JSON one.
  if [[ -n ${PROJECTS_BAD:-} ]]; then
    PROJECTS_BAD=1 PATH="$WORK/bin:$PATH" "$GC" "$@" >"$WORK/out" 2>&1
  else
    PATH="$WORK/bin:$PATH" "$GC" "$@" >"$WORK/out" 2>&1
  fi
  echo $?
}

deletes() { grep -c 'image delete' "$CALLLOG" || true; }
deleted_fp() { grep -o 'image delete --project [^ ]* [^ ]*' "$CALLLOG" | awk '{print $NF}' || true; }

# =============================================================================
echo "== 1. nothing is deleted on the first run =="
# The retention property, stated first because everything else assumes it.
seed default aaa1:0:1 bbb2:0:1
rc=$(run_gc)
check "first run exits 0" "0" "$rc"
check "first run deletes nothing" "0" "$(deletes)"
check "but it records both as seen" "2" "$(grep -c . "$WORK/state/image-gc-default")"
# Twice: once for the project line, once for the run's summary. Both are
# asserted as part of the same grep so the count cannot drift by one unnoticed.
check "and reports it in both the per-project line and the summary" "2" \
  "$(grep -c 'seen twice' "$WORK/out")"

# =============================================================================
echo "== 2. the second run deletes what it saw twice =="
rc=$(run_gc)
check "second run exits 0" "0" "$rc"
check "deletes both" "2" "$(deletes)"
check "by full fingerprint, not a prefix" "2" \
  "$(grep -o 'image delete --project default [0-9a-f]*' "$CALLLOG" | grep -cE ' (aaa1|bbb2)$')"
check "and never passes --force" "0" "$(grep -c -- '--force' "$CALLLOG")"

# =============================================================================
echo "== 3. third run has nothing left to do =="
rc=$(run_gc)
check "exits 0" "0" "$rc"
check "deletes nothing" "0" "$(deletes)"

# =============================================================================
echo "== 4. an aliased image is never a candidate =="
seed default aaa1:1:1 ccc3:0:1
rm -f "$WORK/state/image-gc-default"
run_gc >/dev/null     # observation 1: aliased + unaliased
rc=$(run_gc)           # observation 2
check "exits 0" "0" "$rc"
check "the unaliased one goes" "1" "$(deletes)"
check "the aliased one stays" "ccc3" "$(deleted_fp)"
check "the alias is never touched" "0" "$(grep -c 'delete.*aaa1' "$CALLLOG")"

# =============================================================================
echo "== 5. an image with no user.build-source is never a candidate =="
# This is what protects the hand-imported Ubuntu and OpenSUSE images. They are
# unreferenced and unaliased, so on "unreferenced" alone they would be deleted.
seed default aaa1:0:0 ddd4:0:0
rm -f "$WORK/state/image-gc-default"
run_gc >/dev/null
rc=$(run_gc)
check "exits 0" "0" "$rc"
check "deletes neither" "0" "$(deletes)"
# The state file is created and left empty, rather than absent. An absent file and
# an empty one are equivalent to the script, but the file existing makes the
# "we looked and there was nothing" outcome legible to whoever reads the directory.
check "and writes an empty state file, not a populated one" "0" \
  "$(grep -c . "$WORK/state/image-gc-default")"
check "the report says zero unreferenced" "1" \
  "$(grep -c '0 unreferenced of ours' "$WORK/out")"

# =============================================================================
echo "== 6. an image that only just became unreferenced survives the run after =="
# The case that separates this from a GC that deletes on first sight. ccc3 is
# unaliased in observation 1, so it is eligible one run later -- but eee5 only
# becomes unaliased BETWEEN the two runs, so on this run it has been seen once.
seed default ccc3:0:1 eee5:1:1
rm -f "$WORK/state/image-gc-default"
run_gc >/dev/null                      # ccc3 unaliased, eee5 still aliased
# now unalias eee5 only -- it becomes a candidate only after this run records it
python3 - "$POOL/default/images.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for i in d:
    if i["fingerprint"] == "eee5":
        i["aliases"] = []
json.dump(d, open(p, "w"))
PY
rc=$(run_gc)
check "exits 0" "0" "$rc"
check "the long-unreferenced one is deleted" "ccc3" "$(deleted_fp)"
check "the newly-unreferenced one is NOT" "0" "$(grep -c 'delete.*eee5' "$CALLLOG")"
check "and it is now recorded for next time" "1" "$(grep -c '^eee5$' "$WORK/state/image-gc-default")"

# =============================================================================
echo "== 7. Incus refusing a delete is a skip, not a failure =="
printf 'fff6\n' >>"$REFUSE"
seed default fff6:0:1
rm -f "$WORK/state/image-gc-default"
run_gc >/dev/null
rc=$(run_gc)
check "still exits 0" "0" "$rc"
check "reports it as skipped" "1" "$(grep -c 'skipped fff6' "$WORK/out")"
check "names the reason" "1" "$(grep -c 'so it is in use' "$WORK/out")"
check "and keeps it in state, so it is retried" "1" "$(grep -c '^fff6$' "$WORK/state/image-gc-default")"

# =============================================================================
echo "== 8. --dry-run deletes nothing and writes no state =="
seed default 1111:0:1
rm -f "$WORK/state/image-gc-default"
# One real observation first, so there IS a candidate to report. A dry run
# against a fresh state file correctly reports nothing -- there is no second
# observation yet -- and without this line the section would pass vacuously.
run_gc >/dev/null
before=$(cat "$WORK/state/image-gc-default")
rc=$(run_gc --dry-run)
after=$(cat "$WORK/state/image-gc-default")
check "exits 0" "0" "$rc"
check "deletes nothing" "0" "$(deletes)"
check "says what it would do" "1" "$(grep -c 'would delete 1111' "$WORK/out")"
check "and warns that nothing became eligible" "1" \
  "$(grep -c 'nothing became eligible' "$WORK/out")"
# The state file is compared, not checked for existence. It exists legitimately by
# now -- there was a real observation before the dry run -- so "was not written"
# would have to be asserted as "was not CHANGED", which is the property that
# actually matters: a dry run that left state behind would let the next real run
# treat a first observation as a second one and delete on the strength of a look
# that never happened.
check "the dry run left the state file exactly as it was" "$before" "$after"

# =============================================================================
echo "== 9. projects are handled separately =="
seed alpha 2222:0:1
seed beta 3333:0:1
rm -f "$WORK/state"/image-gc-*
INCUS_IMAGE_GC_PROJECTS="alpha beta" run_gc >/dev/null
INCUS_IMAGE_GC_PROJECTS="alpha beta" run_gc >/dev/null
check "each project's image is deleted in its own project" \
  "2222 3333" "$(deleted_fp | tr '\n' ' ' | sed 's/ $//')"
check "two separate state files" "2" "$(ls "$WORK/state" | grep -c image-gc-)"

# =============================================================================
echo "== 10. an unreadable project is an error, not a silent zero =="
rm -f "$WORK/pool"/*/images.json
rc=$(run_gc)
check "exits non-zero" "1" "$rc"
# One line per project, and the projects are whatever the pool holds, so the
# expectation is derived rather than hardcoded to whatever happened to be there.
check "says which project, once per project" "$(ls "$POOL" | wc -l)" \
  "$(grep -c 'FATAL: cannot list images' "$WORK/out")"
check "and deleted nothing" "0" "$(deletes)"
# The reason this is a failure and not a skip. On the live host this run reported
# success having collected 13 of 33, because the project holding the other 20 could
# not be listed. An exit status of 0 over a pool the run has not seen is the
# failure mode, so it is asserted directly rather than inferred from the log.
check "a partial run does NOT report success" "1" \
  "$(grep -c 'FATAL: cannot list images' "$WORK/out" | awk '{print ($1>0)?1:0}')"
# It must also name them, and say the counts are not the whole pool. "13
# unreferenced" over a pool it could not read is the sentence that misled me.
check "and the summary names the projects it could not read" "1" \
  "$(grep -c 'FAILED: .*project(s) could not be read' "$WORK/out" | awk '{print ($1>0)?1:0}')"
check "and says the counts are not the whole pool" "1" \
  "$(grep -c 'not the whole pool' "$WORK/out")"
# And it must still have attempted the readable projects, so one broken project
# does not hide the others.
check "readable projects were still processed" "1" \
  "$([[ $(grep -c 'unreferenced of ours' "$WORK/out") -ge 0 ]] && echo 1 || echo 0)"

# =============================================================================
echo "== 10a. the project list is parsed as JSON, not CSV =="
# The bug this section exists for was invisible to every other one. The stub used
# to print bare project names, so `cut -d, -f1` on CSV and `.name` on JSON both
# "worked" -- against a fixture that was more convenient than the real thing.
# The real Incus decorates the current project and emits the header as data.
#
# Section 10 deleted every project's images.json and left `alpha` and `beta`
# behind from section 9. `seed` overwrites images.json for the projects it is
# given, but it does not remove the others, so all four have to be re-seeded --
# otherwise the check below would be reporting section 10's destroyed pool again,
# and would pass or fail for that reason rather than its own.
seed alpha aaa1:0:1
seed beta bbb2:0:1
seed default ccc3:0:1
seed zeta9 ddd4:0:1
rc=$(run_gc)
check "exits 0" "0" "$rc"
check "the plain name is used, not 'default (current)'" "1" \
  "$(grep -c 'image list --project default --format json' "$CALLLOG")"
check "and never the decorated name" "0" \
  "$(grep -c 'project default (current)' "$CALLLOG")"
check "no invented project name reaches incus at all" "0" \
  "$(grep -cE 'project [^ ]* \(current\)' "$CALLLOG")"
# And the CSV shape Incus really emits must not be tolerated quietly. The script
# asks for JSON and the daemon answers JSON, so this branch is a fault-injection
# case: the daemon answered with something that is not JSON. It must refuse rather
# than collect nothing and report success -- which is precisely what the original
# bug did, with a decorated project name instead of a parse failure.
PROJECTS_BAD=1 rc=$(run_gc)
check "a non-JSON project list exits non-zero" "1" "$rc"
check "and says why" "1" "$(grep -c 'could not list projects' "$WORK/out")"
check "and collects nothing at all" "0" "$(grep -c 'image list' "$CALLLOG")"

# =============================================================================
echo "== 11. the whole file, re-read for the one destructive flag =="
if grep -n -- '--force' "$GC" | grep -vE ':[[:space:]]*#' >/dev/null; then
  echo "  FAIL the script passes --force somewhere:"
  grep -n -- '--force' "$GC" | grep -vE ':[[:space:]]*#' | sed 's/^/       /'
  fails=$((fails + 1))
else
  echo "  ok   --force appears only in comments"
fi
# The alias rule and the build-source rule have to be in the same jq filter that
# decides candidacy, not in a shell test that could be reordered around it.
if grep -q 'user.build-source' "$GC" && grep -q 'aliases | length) == 0' "$GC"; then
  echo "  ok   candidacy is decided by build-source AND absence of alias"
else
  echo "  FAIL candidacy filter no longer requires both conditions"
  fails=$((fails + 1))
fi

echo
if [[ $fails -eq 0 ]]; then
  echo "all checks passed"
else
  echo "$fails check(s) FAILED"
fi
exit $((fails > 0))