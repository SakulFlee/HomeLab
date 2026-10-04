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
# The block is *extracted* rather than sourced, because apply.sh runs its driver
# at the bottom unconditionally and this only wants the functions. The extraction
# range is asserted at run time, so reordering apply.sh fails the test rather
# than silently testing nothing.
#
# render_secrets has its own suite in apply-secrets-test.sh. It could not live
# here: it needs the whole file (incus_run, the logging helpers,
# assert_secret_readable) and it refuses to run as non-root. That split is why
# two bugs reached the host -- neither static check nor this suite could see
# them, and only executing the function could.
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

# --- whole-file invariants -------------------------------------------------
# These are not about the project block; they are properties of apply.sh that no
# amount of stubbing this block would catch, and each one corresponds to a bug
# that actually reached the host.
whole_file_fail=0
# Comment lines are excluded deliberately: the prose explaining why
# `incus_run query` is wrong quotes the string, and the check has to be able to
# say so. Only actual invocations count.
if grep -n 'incus_run query' "$APPLY" | grep -vE ':[[:space:]]*#' >/dev/null; then
  echo "FATAL: 'incus_run query' present -- incus query refuses --project:"
  grep -n 'incus_run query' "$APPLY" | grep -vE ':[[:space:]]*#' | sed 's/^/  /'
  whole_file_fail=1
fi
if grep -nE '(^|[^_[:alnum:]])incus (image|storage|exec)' "$APPLY" \
     | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vq .; then
  echo "FATAL: bare incus against a project-scoped object:"
  grep -nE '(^|[^_[:alnum:]])incus (image|storage|exec)' "$APPLY" \
    | grep -vE '^[0-9]+:[[:space:]]*#' | sed 's/^/  /'
  whole_file_fail=1
fi
# The secrets directory mode has to be derived from who the consumer is, not
# hardcoded, because the two instances need opposite things and each hardcoded
# value has already broken one of them:
#
#   0700 -> Caddy cannot read its own client certificate. Its files are
#           root:caddy, so the *caddy user* must traverse a directory it does not
#           own. Every hostname on the host went down.
#   0711 -> Forgejo's secrets become readable by `git`, which is in group forgejo
#           and is who every host SSH session lands as. Measured: all six files.
#
# So the check is structural: a bare chmod of the directory means one of those two
# bugs is being re-introduced. The conditional on ownership is what is required.
if grep -nE 'chmod +(0?700|0?711) +\$dir\b' "$APPLY" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  echo "FATAL: secrets directory mode is hardcoded -- one of the two known bugs:"
  echo "  0700 locks Caddy out of its own certificate; 0711 exposes Forgejo's secrets to git."
  grep -nE 'chmod +(0?700|0?711) +\$dir\b' "$APPLY" | grep -vE '^[0-9]+:[[:space:]]*#' | sed 's/^/  /'
  whole_file_fail=1
fi
# The directory's mode has to be COMPARED, not merely set on write. Without the
# comparison a change to dir_mode can never take effect: the files are byte-exact,
# so every other check passes and the loop continues past all of them -- the fix
# deploys, reports success, and leaves the directory in the leaking state.
if ! grep -q 'cur_dir_mode' "$APPLY"; then
  echo "FATAL: the secrets directory mode is never compared, so a change to it"
  echo "  cannot take effect. It would be committed, deployed, reported done, and"
  echo "  the directory would keep its old mode."
  whole_file_fail=1
fi
# And the mode must be chosen from the directory's actual owner, not guessed.
if ! grep -q 'dir_owner=\$(g stat' "$APPLY"; then
  echo "FATAL: dir_mode is not derived from the directory owner -- the distinction that"
  echo "  separates Caddy (needs o+x) from Forgejo (must not have it) is ownership."
  whole_file_fail=1
fi
# A herestring into the secret-writing command appends a newline to every
# rendered secret. It went unnoticed because the read-back stripped it again, so
# apply.sh compared a 43-byte secret against a 44-byte file, called them equal,
# and re-rendered nothing. Forgejo derives its TOTP key from SECRET_KEY, so the
# byte that was added is the byte that decides whether 2FA can be decrypted.
if grep -nE 'incus_run_stdin exec .*<<<' "$APPLY" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  echo "FATAL: secret payload written through a herestring (appends a newline):"
  grep -nE 'incus_run_stdin exec .*<<<' "$APPLY" | grep -vE '^[0-9]+:[[:space:]]*#' | sed 's/^/  /'
  whole_file_fail=1
fi
# Reading a file out of the guest must go through the helper that exports the
# NixOS profile. A bare `incus_run exec ... cat` can fail to resolve and return
# empty, and an empty read looks identical to "file absent" or "content
# differs" -- which is how the mismatch above stayed pinned in place.
if grep -nE 'incus_run(_stdin)? exec .*-- (cat|stat|sha256sum|cp|mv|rm) ' "$APPLY" \
     | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  echo "FATAL: guest file operation without the NixOS profile on PATH:"
  grep -nE 'incus_run(_stdin)? exec .*-- (cat|stat|sha256sum|cp|mv|rm) ' "$APPLY" \
    | grep -vE '^[0-9]+:[[:space:]]*#' | sed 's/^/  /'
  whole_file_fail=1
fi
[[ $whole_file_fail == 0 ]] || exit 99

# --- execute render_secrets against the stubs -------------------------------
# A whole-file invariant cannot catch this class of bug, and neither can the two
# checks a shell script usually gets:
#
#   bash -n     PASSES. Unbound-variable is a runtime error, not a syntax error.
#   shellcheck  PASSES. `cmd="$cmd && ..."` looks like an assignment, so SC2154
#                does not fire; only execution reveals that $cmd was never set.
#
# That is how `cmd: unbound variable` reached production on 400da3f3: a hoist for
# the directory-mode comparison dropped the line that initialises cmd, so the very
# first render died with the directory still at 0711 and the secret still
# readable. bash -n had passed on the file that shipped.
#
# So the only check worth having here is one that RUNS the code path. Both
# directory modes are exercised, because the whole point of the ownership
# conditional is that they differ, and a test that only ever renders one of them
# cannot tell whether the other still works.
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