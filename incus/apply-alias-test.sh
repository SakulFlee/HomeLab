#!/usr/bin/env bash
# Tests for drop_foreign_aliases in incus/apply.sh. Run it: ./incus/apply-alias-test.sh
#
# Pure bash against a stubbed `incus`, so it needs no Incus, no Nix and no root,
# and cannot remove anything real.
#
# The function under test exists because of a bug that no other suite could see.
# `point_alias_at` only ever CREATES an image alias; nothing in apply.sh ever
# removed one. That is invisible until an instance moves between projects, and then
# the alias it left behind is unowned and uncleanable. Measured on the live host
# after forgejo moved into its own project:
#
#   default   homelab/forgejo -> 082a11388142   rev ee3c0279   <- orphan, 324 MB
#   forgejo   homelab/forgejo -> 7a35c719a409   rev 14eb1122   <- live
#
# Two things went wrong from that, and they are what these tests are about:
#
#   * incus-image-gc keeps an image that holds an alias, so the orphan survived a
#     GC that was otherwise flawless and had to be deleted by hand.
#   * Incus does not resolve aliases on most verbs, so `incus image delete
#     homelab/forgejo` resolves to the DEFAULT project's copy -- the wrong one.
set -uo pipefail

APPLY=${APPLY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply.sh}
[[ -f $APPLY ]] || { echo "FATAL: $APPLY not found"; exit 99; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

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

# --- extract just the two functions ------------------------------------------
START=$(grep -n '^incus_project_names()' "$APPLY" | cut -d: -f1)
END=$(grep -n '^# Make the alias name an image' "$APPLY" | cut -d: -f1)
[[ -n $START && -n $END && $START -lt $END ]] \
  || { echo "FATAL: could not locate the drop_foreign_aliases block in apply.sh"; exit 99; }
sed -n "${START},$((END - 1))p" "$APPLY" >"$WORK/block.sh"
for fn in incus_project_names drop_foreign_aliases; do
  grep -q "^${fn}()" "$WORK/block.sh" \
    || { echo "FATAL: $fn not in the extracted block"; exit 99; }
done

# --- the incus stub ----------------------------------------------------------
# Models what matters and nothing else: which project holds which alias, and a
# record of every call. The alias map is a directory, so a test's fixture IS the
# pool, and "did it delete the right thing" is answered by the filesystem rather
# than by parsing a log.
cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf 'incus %s\n' "$*" >>"$CALLLOG"
args=(); project=""; prev=""
for a in "$@"; do
  if [[ $prev == --project ]]; then project=$a; prev=""; continue; fi
  [[ $a == --project ]] && { prev=--project; continue; }
  args+=("$a")
done
# Keyed on a joined prefix, not on "$1 $2": `image alias delete` is THREE words,
# so a two-word match dispatches to the image-list branch and the delete
# silently does nothing -- the stray stays and the suite reports it.
verb=${args[*]:0:2}
verb3=${args[*]:0:3}
case "$verb" in
  "project list")
    # JSON, and `.[].name` -- see the function's comment on why csv is unusable.
    printf '['
    first=1
    for d in "$POOL"/*/; do
      d=${d%/}
      [[ $first == 1 ]] || printf ','
      first=0
      printf '{"name":"%s","description":"","config":{}}' "$(basename "$d")"
    done
    printf ']'
    ;;
  "image list")
    printf '['
    first=1
    for d in "$POOL/$project"/images/*/; do
      d=${d%/}
      f="$d/aliases"
      [[ -f $f ]] || continue
      [[ $first == 1 ]] || printf ','
      first=0
      printf '{"fingerprint":"%s","aliases":[' "$(basename "$d")"
      afirst=1
      while read -r a; do
        [[ -n $a ]] || continue
        [[ $afirst == 1 ]] || printf ','
        afirst=0
        printf '{"name":"%s"}' "$a"
      done <"$f"
      printf ']}'
    done
    printf ']'
    ;;
  *)
    if [[ $verb3 == "image alias delete" ]]; then
    # args: (image alias delete <name> --project <p>) -> the name is args[3].
    # An alias contains a slash, so it lives in a FILE as content and is never a
    # path component. The first fixture used a path and every `alias_at` quietly
    # created aliases/homelab/forgejo instead of an alias named homelab/forgejo --
    # so the function under test was handed an empty pool and every check that
    # depended on a fixture existing failed for a reason that had nothing to do
    # with it.
    name=${args[3]-}
    if [[ -n ${REFUSE:-} && $name == "$REFUSE" ]]; then
      printf 'Error: Failed\n' >&2
      exit 1
    fi
      for f in "$POOL/$project"/images/*/aliases; do
        [[ -f $f ]] || continue
        grep -vxF "$name" "$f" >"$f.tmp" 2>/dev/null || : >"$f"
        mv "$f.tmp" "$f"
      done
    fi
    ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/incus"

export CALLLOG=$WORK/calls
export POOL=$WORK/pool
# The stub has to be found. Without this the REAL incus is called, the suite
# answers 0 checks having exercised nothing, and it looks like the function works.
export PATH="$WORK/bin:$PATH"
: >"$CALLLOG"

reset() {
  rm -rf "$POOL"; mkdir -p "$POOL"
  : >"$CALLLOG"
  : >"$WORK/refuse"
  export REFUSE=
}
# alias_at <project> <alias> [fingerprint]
# The alias is a line in the image's aliases file, never a path component.
alias_at() {
  local project=$1 alias=$2 fp=${3:-img}
  mkdir -p "$POOL/$project/images/$fp"
  printf '%s\n' "$alias" >>"$POOL/$project/images/$fp/aliases"
}
has_alias() { grep -qxF "$2" "$POOL/$1/images/${3:-img}/aliases" 2>/dev/null && echo 1 || echo 0; }

# shellcheck disable=SC1090
source "$WORK/block.sh"

# incus_run is apply.sh's own logging wrapper and lives OUTSIDE the extracted
# block, so it has to be supplied here. Without it the function under test calls
# a command that does not exist and every check fails with "command not found" --
# which is indistinguishable from the function being broken, and cost me one run
# to notice.
incus_run() { incus "$@"; }

# apply.sh's logging helpers, which are also outside the extracted block. They
# are part of the contract: step/warn are how the function tells an operator what
# it did, and section 7 asserts on the warning text, so a suite that stubs them
# away would be testing a function that can no longer report anything.
step() { printf 'step %s\n' "$*" >&2; }
warn() { printf 'warn %s\n' "$*" >&2; }

# The globals apply.sh sets before anything is called. The suite runs under
# `set -u`, so an unset one is an unbound-variable abort the moment the function
# reaches it -- which reads as the function being broken rather than as a fixture
# that did not define the world it runs in.
CHECK_ONLY=0
IMAGE_PREFIX=homelab

# =============================================================================
echo "== 1. a stray alias in another project is removed =="
reset
alias_at default homelab/forgejo
alias_at forgejo homelab/forgejo
drop_foreign_aliases homelab/forgejo forgejo
check "the stray is gone" "0" "$(has_alias default homelab/forgejo)"
check "the live one is untouched" "1" "$(has_alias forgejo homelab/forgejo)"
check "and the command was project-scoped" "1" \
  "$(grep -c 'image alias delete homelab/forgejo --project default' "$CALLLOG")"

# =============================================================================
echo "== 2. it only ever removes an ALIAS, never an image =="
# The image behind a stray has to survive to this point: once the alias is gone
# the image becomes collectable, and incus-image-gc is the component that owns
# image lifetime. Deleting the image here would take that decision away from it
# and throw away the rollback target in the same move.
check "the image the stray alias named still exists" "1" \
  "$(test -d "$POOL/default/images/img" && echo 1 || echo 0)"
check "and no image delete was issued" "0" \
  "$(grep -c '^incus image delete' "$CALLLOG")"

# =============================================================================
echo "== 3. nothing to do is nothing done =="
reset
alias_at forgejo homelab/caddy
drop_foreign_aliases homelab/caddy forgejo
check "no alias delete at all" "0" "$(grep -c 'alias delete' "$CALLLOG")"
check "still no image delete" "0" "$(grep -c '^incus image delete' "$CALLLOG")"

# =============================================================================
echo "== 4. an instance in the DEFAULT project, with another project existing =="
# The `other != project` guard. Getting it wrong makes the function delete the
# alias out from under the instance it was just asked to reconcile.
reset
alias_at default homelab/wireguard
alias_at forgejo homelab/wireguard
drop_foreign_aliases homelab/wireguard default
check "the default project's alias survives" "1" "$(has_alias default homelab/wireguard)"
check "and the forgejo project's does not" "0" "$(has_alias forgejo homelab/wireguard)"

# =============================================================================
echo "== 5. projects come from INCUS, as JSON =="
# Two separate traps, both of which the CSV format walks into: the first line is
# the header, and the current project is decorated "(current)". Using either
# produces a project name that does not exist, so the stray is never found and
# the function reports success having done nothing.
reset
alias_at default homelab/forgejo
drop_foreign_aliases homelab/forgejo forgejo
check "asks Incus for the project list" "1" \
  "$(grep -c '^incus project list --format json$' "$CALLLOG")"
check "never asks for csv" "0" "$(grep -c 'project list --format csv' "$CALLLOG")"
# And it must be Incus's list, not the flake's: the orphan is by definition in a
# place the registry no longer describes, so reading incusProjects cannot find it.
check "does not read the flake's project map" "0" \
  "$(grep -c 'incusProjects' "$CALLLOG")"

# =============================================================================
echo "== 6. --check reports and removes nothing =="
reset
alias_at default homelab/forgejo
alias_at forgejo homelab/forgejo
CHECK_ONLY=1
drop_foreign_aliases homelab/forgejo forgejo
# Back to 0, NOT `unset`. Under `set -u` an unset CHECK_ONLY aborts the next
# section with "unbound variable", which surfaces as the function being broken
# rather than as the previous section having tidied up too well.
CHECK_ONLY=0
check "the stray survives" "1" "$(has_alias default homelab/forgejo)"
check "no delete was issued" "0" "$(grep -c 'alias delete' "$CALLLOG")"

# =============================================================================
echo "== 7. a failed removal warns, and says how to do it by hand =="
# Silence here is the failure mode worth preventing: the alias survives, the GC
# cannot collect the image, and nothing anywhere says why.
reset
alias_at default homelab/forgejo
alias_at forgejo homelab/forgejo
export REFUSE=homelab/forgejo
out=$(drop_foreign_aliases homelab/forgejo forgejo 2>&1); rc=$?
# rc captured on the same line as the call. Reading `$?` on the line AFTER the
# assignment reports the status of whatever ran last in between, which here was a
# `check` -- so the function's own exit status was never observed at all.
check "the function still returns 0" "0" "$rc"
check "it says the alias is still present" "1" \
  "$(grep -c 'is still present in project' <<<"$out")"
check "and gives the exact command" "1" \
  "$(grep -c 'incus image alias delete homelab/forgejo --project default' <<<"$out")"
check "and explains the consequence" "1" \
  "$(grep -c 'incus-image-gc will not collect it' <<<"$out")"
unset REFUSE

# =============================================================================
echo "== 8. no project, no action =="
# $project is empty for an instance in Incus's own default project when the
# caller has not resolved it. Guessing there could delete the live alias.
reset
alias_at default homelab/forgejo
alias_at forgejo homelab/forgejo
# Two projects and a live alias in EACH, so "nothing happened" is a real result and
# not the absence of anything to act on. With only the `default` alias present the
# function has nothing to do under EITHER implementation, so guessing the project
# would be invisible -- which is why this section originally passed against a
# function that guessed.
drop_foreign_aliases homelab/forgejo ""
check "nothing was deleted" "1" "$(has_alias default homelab/forgejo)"
check "nor from a project it was not asked about" "1" "$(has_alias forgejo homelab/forgejo)"
check "and no command was issued" "0" "$(grep -c 'alias delete' "$CALLLOG")"

# =============================================================================
echo "== 9. an empty pool, and a project with no images at all =="
# `incus image list` on an empty project returns [], and `any([])` is false rather
# than an error. If it were an error the function would either warn about a
# project that is fine, or -- worse -- treat every project as a stray.
reset
mkdir -p "$POOL/default" "$POOL/empty"
drop_foreign_aliases homelab/forgejo forgejo
check "an empty pool produces no delete" "0" "$(grep -c 'alias delete' "$CALLLOG")"
check "and no warning about a healthy project" "0" \
  "$(grep -c 'still present' "$CALLLOG")"

echo
if [[ $fails -eq 0 ]]; then
  echo "all checks passed"
else
  echo "$fails check(s) FAILED"
fi
exit $((fails > 0))