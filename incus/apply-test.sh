#!/usr/bin/env bash
# Tests for incus/apply.sh. Run it:  ./incus/apply-test.sh
#
# Exists because apply.sh can be syntactically valid, evaluate cleanly, and
# still be wrong: two separate changes this session reached the host as a green
# build and failed only at Incus. It is pure bash against stubbed `incus` and
# `nix`, so it needs neither Nix, nor Incus, nor root, and cannot touch anything
# real.
#
# Currently covers the project block only (project_qs, projects_json,
# project_settings, ensure_project) -- the part that was wrong three different
# ways. The rest of the script is untested and should not be assumed to be.
#
# The block is *extracted* rather than sourced, because apply.sh runs main() at
# the bottom unconditionally and this only wants the functions. The extraction
# range is asserted at run time, so reordering apply.sh fails the test rather
# than silently testing nothing.
set -uo pipefail

APPLY=${APPLY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply.sh}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- extract the block under test -----------------------------------------
START=$(grep -n '^project_qs()' "$APPLY" | cut -d: -f1)
END=$(grep -n '^incus_run()' "$APPLY" | cut -d: -f1)
sed -n "${START},$((END - 1))p" "$APPLY" >"$WORK/block.sh"
for fn in project_qs projects_json project_settings ensure_project project_field; do
  grep -q "^${fn}()" "$WORK/block.sh" || { echo "FATAL: $fn not in extracted block"; exit 99; }
done

# --- stubs -----------------------------------------------------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
# Fake project store. $STATEDIR/<project>/config.<key> holds config keys and
# $STATEDIR/<project>/field.<key> holds top-level fields, so that reading the
# wrong namespace comes back empty exactly as the real Incus would.
log() { printf '%s\n' "$*" >>"$CALLLOG"; }
show() {
  local p=$1
  [[ -d $STATEDIR/$p ]] || return 1
  # JSON, because `incus project show` is YAML-only in the real CLI and the code
  # deliberately goes through `incus query` for that reason.
  printf '{"config":{'
  local first=1 f k
  for f in "$STATEDIR/$p"/config.*; do
    [[ -e $f ]] || continue
    k=${f##*/config.}
    [[ $first == 1 ]] || printf ','
    first=0
    printf '"%s":"%s"' "$k" "$(cat "$f")"
  done
  printf '},"description":"%s","name":"%s"}' \
    "$(sed -n 's/^description=//p' "$STATEDIR/$p"/fields 2>/dev/null)" "$p"
}
case $1 in
  project)
    case $2 in
      show) show "$3" ;;
      create)
        log "project create $3"
        mkdir -p "$STATEDIR/$3"
        ;;
      set)
        log "project set $3 $4"
        # Mirror the real CLI: only the features/ namespace is settable.
        [[ $4 == features.* ]] || { printf 'Error: Invalid project configuration key "%s"\n' "${4%%=*}"; exit 1; }
        mkdir -p "$STATEDIR/$3"
        printf '%s' "${4#*=}" >"$STATEDIR/$3/config.${4%%=*}"
        ;;
      *) log "UNEXPECTED project subcommand: $2 $3" ;;
    esac
    ;;
  query)
    if [[ $2 == -X && $3 == PATCH && $4 == /1.0/projects/* ]]; then
      p=${4##*/}
      body=$6
      log "query PATCH $4 $body"
      mkdir -p "$STATEDIR/$p"
      printf '%s' "$body" \
        | jq -r 'keys[0] as $k | "\($k)=\(.[$k])"' \
        >"$STATEDIR/$p/fields"
    elif [[ $2 == /1.0/projects/* ]]; then
      show "${2##*/}" || exit 1
      printf '\n'
    else
      log "UNEXPECTED query invocation: $*"
    fi
    ;;
  *) log "UNEXPECTED incus invocation: $*" ;;
esac
STUB

cat >"$WORK/bin/nix" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$PROJECTS_JSON"
STUB
chmod +x "$WORK/bin/incus" "$WORK/bin/nix"

export PATH="$WORK/bin:$PATH"
export STATEDIR CALLLOG

# Globals the block reads.
PROJECT=""
CHECK_ONLY=0
FLAKE_DIR="/nonexistent"
TAG="test"
log()  { printf '%-9s %s\n' "$TAG" "$*" >&2; }
step() { printf '%-9s == %s\n' "$TAG" "$*" >&2; }
warn() { printf '%-9s WARN: %s\n' "$TAG" "$*" >&2; }
die()  { printf '%-9s ERROR: %s\n' "$TAG" "$*" >&2; exit 1; }

# shellcheck source=/dev/null
. "$WORK/block.sh"

PROJECTS_JSON='{"forgejo":{"description":"HomeLab Forgejo","features":{"images":true,"profiles":false}}}'
export PROJECTS_JSON

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

reset() { rm -rf "$STATEDIR"; mkdir -p "$STATEDIR"; CALLLOG=$(mktemp); export CALLLOG; }
STATEDIR=$(mktemp -d)
export STATEDIR

echo "== 1. project absent: created and converged =="
reset
PROJECT=forgejo
ensure_project
check "created"          "1"  "$(grep -c '^project create forgejo$' "$CALLLOG")"
check "description via API" "1" "$(grep -c '^query PATCH /1.0/projects/forgejo {"description":"HomeLab Forgejo"}$' "$CALLLOG")"
check "images as config"  "1"  "$(grep -c '^project set forgejo features.images=true$' "$CALLLOG")"
check "profiles as config" "1" "$(grep -c '^project set forgejo features.profiles=false$' "$CALLLOG")"
check "no stray calls"   "0"  "$(grep -c '^UNEXPECTED' "$CALLLOG")"

echo "== 2. second run is a pure no-op =="
CALLLOG2=$(mktemp); export CALLLOG=$CALLLOG2
ensure_project
check "no writes at all" "0"  "$(wc -l <"$CALLLOG2" | tr -d ' ')"

echo "== 3. drift: features.images forced back to false =="
printf 'false' >"$STATEDIR/forgejo/config.features.images"
CALLLOG3=$(mktemp); export CALLLOG=$CALLLOG3
ensure_project
check "only images fixed" "1" "$(grep -c '^project set forgejo features.images=true$' "$CALLLOG3")"
check "description alone" "0" "$(grep -c 'description' "$CALLLOG3")"

echo "== 3a. description is not a config key =="
# The real CLI says `Error: Invalid project configuration key "description"`,
# which killed a full reconcile for a cosmetic field. The stub refuses it too,
# so routing it through `project set` fails here rather than on the host.
reset
PROJECT=forgejo
ensure_project >/dev/null 2>&1
check "description is a top-level field" "HomeLab Forgejo" "$(sed -n 's/^description=//p' "$STATEDIR/forgejo/fields")"
check "not stored as a config key"      ""                     "$(cat "$STATEDIR/forgejo/config.description" 2>/dev/null)"

echo "== 3b. a false value is a value, not an absent one =="
# The trap this guards: `false` read as "unset" would mean features.profiles is
# re-PATCHed on every single run of the fifteen-minute reconcile timer, and the
# project would keep its own empty profile -- i.e. the root-disk failure again.
reset
PROJECT=forgejo
ensure_project >/dev/null 2>&1
CALLLOG3b=$(mktemp); export CALLLOG=$CALLLOG3b
ensure_project
check "profiles=false kept" "false" "$(cat "$STATEDIR/forgejo/config.features.profiles")"
check "no rewrite of it"  "0" "$(grep -c 'features.profiles' "$CALLLOG3b")"
check "no writes at all"  "0" "$(wc -l <"$CALLLOG3b" | tr -d ' ')"

echo "== 4. default project: no project work at all =="
reset
PROJECT=""
CALLLOG4=$(mktemp); export CALLLOG=$CALLLOG4
ensure_project
check "nothing touched"  "0" "$(wc -l <"$CALLLOG4" | tr -d ' ')"

echo "== 5. --check reports a missing project but creates nothing =="
reset
PROJECT=forgejo
CHECK_ONLY=1
ensure_project
check "created nothing"  "0"  "$(ls -A "$STATEDIR" | wc -l | tr -d ' ')"
check "still reported"   "1"  "$(ensure_project 2>&1 >/dev/null | grep -c 'does not exist')"

echo "== 6. project_qs =="
PROJECT=""
check "default -> empty"  ""      "$(project_qs)"
PROJECT=forgejo
check "named -> ?project" "?project=forgejo" "$(project_qs)"

echo
if [[ $fails -eq 0 ]]; then
  echo "all checks passed"
else
  echo "$fails check(s) FAILED"
fi
exit $((fails > 0))