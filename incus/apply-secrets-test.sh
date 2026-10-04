#!/usr/bin/env bash
# Exercise render_secrets end-to-end against stubbed incus/nix, and drive the
# directory-mode comparison in the cases that matter.
#
# Extracted separately from the project block above because render_secrets needs
# the whole file (incus_run, log/step/warn/die, assert_secret_readable) and runs
# as root, which the project block does not.
set -uo pipefail

APPLY=${APPLY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply.sh}
export APPLY
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/root" "$WORK/guest"

# --- stubs ------------------------------------------------------------------
# incus: records calls, and fakes the guest side of a render. The guest file
# lives under $GUESTROOT so stat/sha256sum/chmod against it behave for real.
cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLLOG"
# incus_run strips the project flag; the stub just needs to find it and skip it.
args=()
for a in "$@"; do
  case "$a" in --project) skip=1; continue ;; *) ;; esac
  if [[ ${skip:-0} == 1 ]]; then skip=0; continue; fi
  args+=("$a")
done
set -- "${args[@]}"
[[ ${1:-} == exec ]] && shift
inst=${1:-}; shift
[[ ${1:-} == -- ]] && shift
# Rejoin the remainder. `incus exec -- systemctl is-active foo` arrives as three
# argv words, so taking only $1 leaves cmd="systemctl" and every case below fails
# to match -- which looks exactly like a broken test rather than a broken stub.
cmd="$*"
# emulate `sh -c '<cmd>' [stdin]`
printf '%s' "$inst|$cmd" >>"$GUESTCALLS"
# Run the command's observable parts for real against the fake guest.
dir=$(printf '%s' "$cmd" | grep -oE 'mkdir -p [^ ]+' | awk '{print $3}')
# There are TWO chmods in the chain -- one for the directory, one for the file --
# so take them positionally rather than with `tail -1`, or the directory ends up
# carrying 0440 and every assertion below is wrong for the right code.
all_modes=$(printf '%s' "$cmd" | grep -oE 'chmod 0[0-7]+ [^ ]+' | awk '{print $2}')
dir_mode_cmd=$(printf '%s' "$all_modes" | sed -n 1p)
file_mode_cmd=$(printf '%s' "$all_modes" | sed -n 2p)
path=$(printf '%s' "$cmd" | grep -oE 'cat > [^ ]+' | sed 's/cat > //' | head -1)
if [[ -n $dir ]]; then mkdir -p "$GUESTROOT" 2>/dev/null; mkdir -p "$GUESTROOT$dir" 2>/dev/null; fi
if [[ -n $dir_mode_cmd && -n $dir ]]; then chmod "$dir_mode_cmd" "$GUESTROOT$dir" 2>/dev/null; fi
if [[ -n $path ]]; then
  cat >"$GUESTROOT$path"
  chmod "${file_mode_cmd:-0440}" "$GUESTROOT$path" 2>/dev/null
  # Record the group the command asked for. A real chgrp cannot work here --
  # "forgejo" and "caddy" do not exist as host groups -- so without this, stat -c
  # %G reports `root`, the group comparison fails on every pass, and the tree looks
  # permanently out of date.
  printf '%s' "$path" >"$GUESTROOT$path.g"
  printf '%s\n' "$(printf '%s' "$cmd" | grep -oE 'chgrp [^ ]+' | awk '{print $2}')" >"$GUESTROOT$path.group"
fi

# Answer the read-only probes render_secrets makes before deciding whether to
# write. Without these every read comes back empty, which the code correctly
# treats as "unknown", and the ownership fallback fires on every run.
case $cmd in
  *"stat -c %U"*)  echo "$GUEST_DIR_OWNER"; exit 0 ;;
  *"stat -c %a"*)  f=$(printf '%s' "$cmd" | grep -oE '[^ ]+$'); stat -c '%a' "$GUESTROOT$f" 2>/dev/null || true; exit 0 ;;
  *"stat -c %G"*)  f="$GUESTROOT$(printf '%s' "$cmd" | grep -oE '[^ ]+$')"; [ -f "$f.group" ] && cat "$f.group" || stat -c '%G' "$f" 2>/dev/null; exit 0 ;;
  *sha256sum*)     f=$(printf '%s' "$cmd" | grep -oE '[^ ]+$'); [ -f "$GUESTROOT$f" ] && sha256sum "$GUESTROOT$f" | cut -d" " -f1; exit 0 ;;
  *is-active*)     echo active; exit 0 ;;
  *journalctl*)    exit 0 ;;
  *"cat "*)        exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/incus"

cat >"$WORK/bin/nix" <<'STUB'
#!/usr/bin/env bash
echo '{}'
STUB
chmod +x "$WORK/bin/nix"

export PATH="$WORK/bin:$PATH"

# --- extract the whole script, minus the top-level driver ------------------
# apply.sh has no main(): it defines functions, then executes driver code at
# column 0 near the end (argument parsing, then the reconcile loop). Sourcing
# would run all of it. Cut at the first line in the final third that starts in
# column 0 and is not a function definition -- that is where the driver starts.
# apply.sh has no main(): it defines functions, then runs driver code at column 0
# near the end -- argument parsing and the reconcile loop. Sourcing would run all
# of it, including `command -v incus` and the reconcile loop itself.
#
# Anchored on `warn_dirty_tree` as the first driver statement rather than on
# "first line in column 0", because `set -Eeuo pipefail` and the PATH pin are also
# column 0 and appear at line 65 -- a purely positional rule cut the file in two.
# Everything from the argument-parsing `while` onwards is driver code. Anchor on
# it rather than on a line number, and assert the anchor is unique so a reordering
# of apply.sh fails this test rather than silently testing less.
CUT=$(grep -n '^while \[\[ $# -gt 0 \]\]; do$' "$APPLY" | head -1 | cut -d: -f1)
N=$(grep -c '^while \[\[ $# -gt 0 \]\]; do$' "$APPLY")
if [[ -z ${CUT:-} || $N -ne 1 ]]; then
  echo "FATAL: expected exactly one top-level argument loop, found $N"
  exit 99
fi
echo "    (argument loop at line $CUT; extracting definitions from 1..$((CUT - 1)))"
sed -n "1,$((CUT - 1))p" "$APPLY" >"$WORK/apply-fns.sh"
if ! grep -q '^render_secrets()' "$WORK/apply-fns.sh"; then
  echo "FATAL: render_secrets not extracted"; exit 99
fi
# Argument parsing runs at column 0 before the driver section, and dies without
# an instance name. Give it the globals it reads and a name, then let it parse
# harmlessly -- this test calls render_secrets directly, not apply_instance.
# shellcheck disable=SC1090
# Source the extracted functions with the driver body removed too, so nothing
# here depends on argument parsing, `command -v incus`, or FLAKE_DIR.
source "$WORK/apply-fns.sh" || { echo "FATAL: could not source apply.sh functions"; exit 99; }
if ! declare -F render_secrets >/dev/null; then
  echo "FATAL: render_secrets undefined after source"; exit 99
fi

# render_secrets refuses to run as non-root, by design:
#
#   [[ $EUID -eq 0 ]] || die "$name declares renderedSecrets but apply.sh is not root"
#
# That guard is correct and stays. The consequence is only that this test needs
# root, so it skips rather than pretending to pass -- a test that quietly asserts
# nothing is worse than one that says it did not run.
if [[ $EUID -ne 0 ]]; then
  echo "SKIP: render_secrets requires root (EUID 0). Re-run with sudo to exercise it."
  exit 0
fi

fails=0
check() { # label expected actual
  if [[ $2 == "$3" ]]; then printf '    ok   %s\n' "$1"
  else printf '    FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}

# A spec whose directory is OWNED by the consumer group (the forgejo shape) and
# one whose directory is owned by root (the caddy shape). Same function, same
# files, opposite correct answer -- which is the whole reason dir_mode exists.
# A tree that is entirely correct EXCEPT the directory mode, built explicitly
# rather than by rendering first.
#
# Rendering first would already fix the directory -- which is exactly the bug the
# comparison case exists to catch, and it is why that case passed for the wrong
# reason when it reused the tree an earlier case had already rendered.
seed_correct_tree() { # guestroot dir dir_mode
  local root=$1 dir=$2 dmode=$3
  mkdir -p "$root$dir"
  # The seeded bytes must match what apply.sh will want, which is
  # `value=$(<"$source")` -- command substitution strips the trailing newline. So
  # the file on disk gets NO trailing newline, exactly as apply.sh writes secrets.
  # A trailing \n here makes the digest comparison fail and the tree look stale,
  # which reads as a code bug and is not one.
  printf 'secret-value' >"$root$dir/secret_key"
  chmod 0440 "$root$dir/secret_key"
  printf '%s\n' forgejo >"$root$dir/secret_key.group"
  chmod "$dmode" "$root$dir"
}

spec_owned() {
  cat <<JSON
{"renderedSecrets":[
 {"file":"secret_key","format":"raw","source":"$WORK/root/secret_key","mode":"0440","group":"forgejo","dir":"/var/lib/forgejo/custom/conf"}
],"secretConsumers":["forgejo.service"]}
JSON
}
spec_root() {
  cat <<JSON
{"renderedSecrets":[
 {"file":"incus-client.crt","format":"raw","source":"$WORK/root/client.crt","mode":"0440","group":"caddy","dir":"/var/lib/incus-secrets"}
],"secretConsumers":["caddy.service"]}
JSON
}

run_case() { # label spec dir_on_host dir_owner expect_dir_mode
  local label=$1 spec=$2 dir=$3 owner=$4 want=$5
  echo "== $label =="
  export CALLLOG=$WORK/calls GUESTCALLS=$WORK/guest-calls GUESTROOT=$WORK/guest
  : >"$CALLLOG"; : >"$GUESTCALLS"
  mkdir -p "$GUESTROOT$dir"
  # What the guest's `stat -c %U` reports for this directory. A name, not a uid,
  # because that is what gets compared against the consumer group.
  export GUEST_DIR_OWNER=$owner
  # Idempotence matters: render once (creates), then again (should skip).
  if ! out=$(render_secrets forgejo "$spec" 2>&1); then
    printf '    FAIL %s: render_secrets exited non-zero:\n' "$label"
    printf '%s\n' "$out" | sed 's/^/      /'
    fails=$((fails+1))
    return
  fi
  check "$label: no unbound-variable or other error" "" \
    "$(printf '%s' "$out" | grep -E 'unbound variable|line [0-9]+:' | head -1)"
  check "$label: directory mode" "$want" "$(stat -c '%a' "$GUESTROOT$dir" 2>/dev/null)"
  printf '%s\n' "$out" | grep -E 'WARN|rendering' | sed 's/^/    | /'
}

echo "== render_secrets runs at all (the 400da3f3 crash) =="
echo "  cmd is initialised by the PATH export before first use; if that line is"
echo "  ever lost again this case dies with 'cmd: unbound variable'."

printf 'secret-value\n' >"$WORK/root/secret_key"
printf 'cert-bytes\n'    >"$WORK/root/client.crt"

run_case "consumer owns the dir -> 0700" "$(spec_owned)" \
  /var/lib/forgejo/custom/conf forgejo 700
run_case "root owns the dir -> 0711 fallback" "$(spec_root)" \
  /var/lib/incus-secrets root 711

echo
echo "== the comparison: a wrong directory mode must trigger a re-render =="
export CALLLOG=$WORK/c2 GUESTCALLS=$WORK/g2-calls GUESTROOT=$WORK/g2 GUEST_DIR_OWNER=forgejo
# Seeded via seed_correct_tree, not mkdir+chmod: a bare directory with no secret
# file in it sets needs_write for the wrong reason (the file is absent), so the
# assertion below would pass with the directory-mode comparison deleted. The flaw
# under test has to be the ONLY thing wrong.
seed_correct_tree "$GUESTROOT" /var/lib/forgejo/custom/conf 711
spec=$(spec_owned)
out=$(render_secrets forgejo "$spec" 2>&1)
if printf '%s' "$out" | grep -q 'rendering forgejo:secret_key'; then
  echo "    ok   wrong dir mode is detected and re-rendered"
else
  echo "    FAIL dir mode 711 vs want 700 was not detected -- the fix could never apply"
  fails=$((fails+1))
fi
check "  and the mode is now correct" "700" \
  "$(stat -c '%a' "$GUESTROOT/var/lib/forgejo/custom/conf")"

echo
echo "== idempotence: a correct tree must be left alone =="
# A correctly-seeded tree: content, file mode, group and directory mode all
# match what apply.sh wants, so there is nothing to do.
seed_correct_tree "$GUESTROOT" /var/lib/forgejo/custom/conf 700
out=$(render_secrets forgejo "$spec" 2>&1)
if printf '%s' "$out" | grep -q 'rendering'; then
  echo "    FAIL re-rendered an already-correct tree"
  printf '%s\n' "$out" | grep -E 'rendering|WARN' | sed 's/^/      /'
  fails=$((fails+1))
else
  echo "    ok   no work needed, nothing rendered"
fi

echo
if [[ $fails -eq 0 ]]; then echo "render_secrets checks passed"
else echo "$fails render_secrets check(s) FAILED"; fi
exit $((fails > 0))