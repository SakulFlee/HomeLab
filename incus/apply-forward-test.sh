#!/usr/bin/env bash
# Tests for the network-forward half of incus/apply.sh. Run it:
#   ./incus/apply-forward-test.sh
#
# Separate from apply-test.sh on purpose. That file's header states exactly what
# it covers, and that claim is worth keeping true; these tests need a different
# `incus` stub (network forward, not project) and a different `nix` stub
# (incusInstances, not incusProjects), which do not compose into one process.
#
# Why this suite exists at all: the bug this guards is not hypothetical and not
# subtle. Incus keys a network forward by (network, listen_address) -- there is
# ONE forward per address and its port list is shared by every instance pointing
# at it. Caddy holds 80 and 443 on 192.168.178.200. Forgejo then wanted 22 on
# the same address.
#
# A reconciler that computed `want` from the instance it was reconciling alone
# would compute
#
#   want = [tcp 22 -> 10.0.0.101]
#   have = [tcp 80 -> 10.0.0.100, tcp 443 -> 10.0.0.100]
#
# and the removal loop -- which runs first, deliberately -- would take 80 and 443
# off the public site. Every hostname on the homelab 404s, on the next
# unattended run of incus-reconcile.timer, with no error and nothing in the log
# beyond a `step` line. That was caught by reading the code before deploying, not
# by a test, which is exactly the situation this suite is meant to end.
#
# Pure bash against stubbed `incus` and `nix`: no Nix, no Incus, no root, and it
# cannot touch anything real.
set -uo pipefail

APPLY=${APPLY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply.sh}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- extract the code under test -------------------------------------------
# in_list is needed because the removal and add loops both use it, and its
# exact-match semantics are part of what makes the union correct. flake_instances
# and instance_spec are what forward_declarations reads its union from.
FWD_START=$(grep -n '^forward_listing()' "$APPLY" | cut -d: -f1)
FWD_END=$(grep -n '^sync_network_forward()' "$APPLY" | cut -d: -f1)
sed -n "${FWD_START},$((FWD_END + 200))p" "$APPLY" >"$WORK/fwd-raw.sh"
# Trim at the end of sync_network_forward: everything after it in the file is
# unrelated, and sourcing it would drag in half the reconciler.
END=$(awk '/^sync_network_forward\(\)/{d=1} d&&/^}$/{print NR; exit}' "$WORK/fwd-raw.sh")
sed -n "1,${END}p" "$WORK/fwd-raw.sh" >"$WORK/block.sh"
sed -n "$(grep -n '^in_list()' "$APPLY" | cut -d: -f1),$(( $(grep -n '^in_list()' "$APPLY" | cut -d: -f1) + 7 ))p" "$APPLY" >"$WORK/in_list.sh"
sed -n "$(grep -n '^flake_instances()' "$APPLY" | cut -d: -f1),$(( $(grep -n '^instance_spec()' "$APPLY" | cut -d: -f1) + 4 ))p" "$APPLY" >"$WORK/flake.sh"

for fn in forward_listing forward_ports declared_forwards forward_declarations forward_params sync_network_forward; do
  grep -q "^${fn}()" "$WORK/block.sh" || { echo "FATAL: $fn not in extracted block"; exit 99; }
done
for fn in in_list; do
  grep -q "^${fn}()" "$WORK/in_list.sh" || { echo "FATAL: $fn not extracted"; exit 99; }
done
for fn in flake_instances instance_spec; do
  grep -q "^${fn}()" "$WORK/flake.sh" || { echo "FATAL: $fn not extracted"; exit 99; }
done

# The reporter, from report_existing_drift to the trust block that ends it. It is
# here because it is the other half of the same decision: it reads the forward to
# decide whether to warn, and it has to read it the way the reconciler does.
# Located by scanning forward from report_existing_drift rather than to a named
# function: set_description comes BEFORE it in the file, so "up to set_description"
# yields a negative range, sed produces one line, and the resulting . report.sh
# defines nothing. The test then failed with "command not found" while the
# extraction check above it passed -- because the check only asked whether the
# signature was present, and the signature was: it was just the body that was
# missing. Hence the balance check too.
RPT_START=$(grep -n '^report_existing_drift()' "$APPLY" | cut -d: -f1)
RPT_END=$(awk -v s="$RPT_START" 'NR > s && /^}$/ { print NR; exit }' "$APPLY")
sed -n "${RPT_START},${RPT_END}p" "$APPLY" >"$WORK/report.sh"
grep -q '^report_existing_drift()' "$WORK/report.sh" \
  || { echo "FATAL: report_existing_drift not extracted"; exit 99; }
grep -q 'networkForward\|forward_params\|forward_declarations' "$WORK/report.sh" \
  || { echo "FATAL: the extracted reporter has no forward logic in it"; exit 99; }
grep -q 'instance_field\|incus_run' "$WORK/report.sh" \
  || { echo "FATAL: the extracted reporter looks truncated"; exit 99; }

# --- stubs ------------------------------------------------------------------
mkdir -p "$WORK/bin"

cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
# Fake Incus network-forward store. State lives in $FWDSTATE/forwards.json as
# the array `incus network forward list --format json` would print, so the code
# under test reads the same shape it reads on the host.
#
# Every mutation reads the whole state BEFORE writing any of it, and writes
# through a temporary file. The obvious `jq ... <<<"$(fwd)" | save`, where save
# is `cat > file`, is a race: the two halves of the pipeline start concurrently,
# so `cat >` can truncate the state before the other side's `$(fwd)` has read
# it. The result is jq parsing an empty file and writing an empty state, which
# looks exactly like the code under test deleting every port. Two of these tests
# failed that way before this was fixed, and the failure pointed at apply.sh
# rather than at the stub.
log() { printf '%s\n' "$*" >>"$CALLLOG"; }
fwd() { cat "$FWDSTATE/forwards.json" 2>/dev/null || printf '[]'; }
# $1 = the already-read state; stdin = the new state.
save() { cat >"$FWDSTATE/.tmp" && mv "$FWDSTATE/.tmp" "$FWDSTATE/forwards.json"; }

case $1 in
  network)
    case $2 in
      forward)
        case $3 in
          list) fwd ;;
          create)
            # incus takes the target address as an optional third argument.
            log "network forward create $4 $5 ${6:-}"
            st=$(fwd)
            jq --arg l "$4" --arg t "${6:-}" \
              '. + [{listen_address:$l, target_address:$t, ports:[]}]' \
              <<<"$st" | save
            ;;
          port)
            case $4 in
              add)
                log "network forward port add $5 $6 $7 $8 $9 ${10}"
                st=$(fwd)
                jq --arg l "$6" --arg p "$7" --arg lp "$8" \
                      --arg ta "$9" --arg tp "${10}" '
                  map(if .listen_address == $l
                       then .ports += [{protocol:$p, listen_port:($lp|tonumber),
                                        target_port:($tp|tonumber),
                                        target_address:$ta}]
                       else . end)' <<<"$st" | save
                ;;
              remove)
                log "network forward port remove $5 $6 $7 $8"
                st=$(fwd)
                jq --arg l "$6" --arg p "$7" --arg lp "$8" '
                  map(if .listen_address == $l
                       then .ports |= map(select(.protocol != $p
                                              or (.listen_port|tostring) != $lp))
                       else . end)' <<<"$st" | save
                ;;
              *) log "UNEXPECTED network forward port $4 $*" ;;
            esac
            ;;
          *) log "UNEXPECTED network forward $3 $*" ;;
        esac
        ;;
      *) log "UNEXPECTED network $2 $*" ;;
    esac
    ;;
  *) log "UNEXPECTED incus invocation: $*" ;;
esac
STUB

cat >"$WORK/bin/nix" <<'STUB'
#!/usr/bin/env bash
# Serves the instance registry from $INSTANCES_JSON so the union in
# forward_declarations has something real to read. An unreadable registry has to
# be able to fail loudly, which $NIX_BROKEN does -- see test 6.
[[ -n ${NIX_BROKEN:-} ]] && exit 1
attr=""
for a in "$@"; do
  case $a in
    *\#incusInstances)   attr="incusInstances" ;;
    *\#incusInstances.*) attr="${a##*\#incusInstances.}" ;;
  esac
done
[[ -n $attr ]] || exit 1
if [[ $attr == incusInstances ]]; then
  # A JSON ARRAY, not one name per line. `nix eval --json --apply
  # builtins.attrNames` prints ["caddy","forgejo"] on a single line, and
  # flake_instances is what turns that into a list -- via `jq -r '.'[]`, which
  # fails on newline-separated names with
  #
  #   jq: parse error: Invalid numeric literal at line 2, column 0
  #
  # and yields an empty list, which forward_declarations then reads as a dead
  # registry. A stub that "helpfully" printed the names one per line reproduced
  # exactly that failure while looking correct.
  jq -c 'keys' <<<"$INSTANCES_JSON"
else
  jq -c --arg k "$attr" '.[$k]' <<<"$INSTANCES_JSON"
fi
STUB
chmod +x "$WORK/bin/incus" "$WORK/bin/nix"

export PATH="$WORK/bin:$PATH"
export FWDSTATE CALLLOG NIX_BROKEN
FWDSTATE=$(mktemp -d); export FWDSTATE
export INSTANCES_JSON

# Globals the code under test reads.
PROJECT=""
CHECK_ONLY=0
FLAKE_DIR="/nonexistent"
TAG="fwd"
log()  { printf '%-9s %s\n' "$TAG" "$*" >&2; }
step() { printf '%-9s == %s\n' "$TAG" "$*" >&2; }
warn() { printf '%-9s WARN: %s\n' "$TAG" "$*" >&2; }
die()  { printf '%-9s ERROR: %s\n' "$TAG" "$*" >&2; exit 1; }

# A thin stand-in for apply.sh's incus_run. The real one adds --project and the
# log line; neither is what is under test, and sourcing it would drag in the
# whole file. The </dev/null is kept, because that is the part with a history.
incus_run() { incus "$@" </dev/null; }

# The reporter reads instance state, image properties and limits before it gets
# to the forward. None of that is what these tests are about, so each is stubbed
# to a plausible fixed answer -- but they all have to EXIST, because apply.sh runs
# under `set -u` and a single unbound global makes the reporter exit before any
# forward logic runs. That failure mode is indistinguishable from "correct, no
# drift": the reporter simply prints nothing. Every name the reporter touches is
# therefore declared here rather than left to chance.
IMAGE_PREFIX="images"
MANAGED_LIMITS=()
instance_field()      { printf 'Running'; }
instance_json()       { printf '{"devices":{}}'; }
device_matches()      { return 0; }
store_name()          { printf 'nixos-lxc-image-x86_64-linux'; }
assert_secret_readable() { :; }

# shellcheck source=/dev/null
. "$WORK/in_list.sh"
# shellcheck source=/dev/null
. "$WORK/flake.sh"
# shellcheck source=/dev/null
. "$WORK/block.sh"
# shellcheck source=/dev/null
. "$WORK/report.sh"

# --- fixtures ---------------------------------------------------------------
# The real shapes, read off the running host: Caddy on the public address with
# 80/443 to 10.0.0.100, Forgejo claiming 22 on the same address to 10.0.0.101.
CADDY_SPEC='{
  "devices": { "eth0": { "type": "nic", "network": "incusbr0" } },
  "networkForward": {
    "listenAddress": "192.168.178.200",
    "targetAddress": "10.0.0.100",
    "ports": [
      { "protocol": "tcp", "listenPort": 80 },
      { "protocol": "tcp", "listenPort": 443 }
    ]
  }
}'
FORGEJO_SPEC='{
  "devices": { "eth0": { "type": "nic", "network": "incusbr0" } },
  "networkForward": {
    "listenAddress": "192.168.178.200",
    "targetAddress": "10.0.0.101",
    "ports": [ { "protocol": "tcp", "listenPort": 22 } ]
  }
}'
INSTANCES_JSON="$(jq -nc --argjson c "$CADDY_SPEC" --argjson f "$FORGEJO_SPEC" \
  '{caddy:$c, forgejo:$f}')"

live_forward() {
  cat <<'JSON'
[{"listen_address":"192.168.178.200","target_address":"10.0.0.100",
  "ports":[{"protocol":"tcp","listen_port":80,"target_port":80,"target_address":"10.0.0.100"},
           {"protocol":"tcp","listen_port":443,"target_port":443,"target_address":"10.0.0.100"}]}]
JSON
}

reset_fwd() {
  live_forward >"$FWDSTATE/forwards.json"
  CALLLOG=$(mktemp); export CALLLOG
  NIX_BROKEN=""
  : >"$CALLLOG"
}
ports_now() { jq -r '.[0].ports[]?.listen_port' \
  <<<"$(cat "$FWDSTATE/forwards.json")" | sort -n | paste -sd, - ; }

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
check_empty() {
  local what=$1
  if [[ -s $CALLLOG ]]; then
    printf '  FAIL %s -- nothing should have been called:\n' "$what"
    sed 's/^/         /' "$CALLLOG"
    fails=$((fails + 1))
  else
    printf '  ok   %s\n' "$what"
  fi
}

echo "== 1. forward_declarations is the union across instances, not one spec =="
# Command substitution, not `mapfile < <(...)`: forward_declarations can die, and
# in a process substitution that exit is invisible here -- mapfile just gets
# nothing and carries on. The same trap the test suite exists to catch, so it does
# not get to sit inside the suite as well.
union() { forward_declarations incusbr0 192.168.178.200; }
want_lines=$'tcp 22 22 10.0.0.101\ntcp 443 443 10.0.0.100\ntcp 80 80 10.0.0.100'
check "all three ports" "$want_lines" "$(union)"

echo "== 2. reconciling Forgejo must NOT take Caddy's 80/443 off the public site =="
# THE outage. The instance being reconciled declares only port 22; 80 and 443
# belong to a different instance on the same listen address.
reset_fwd
sync_network_forward forgejo "$FORGEJO_SPEC" 2>/dev/null
check "no removals at all" "0" "$(grep -c 'port remove' "$CALLLOG")"
check "only 22 added" "1" "$(grep -c 'port add .* tcp 22 ' "$CALLLOG")"
check "ports now" "22,80,443" "$(ports_now)"
check "80 still to caddy" "10.0.0.100" \
  "$(jq -r '.[0].ports[] | select(.listen_port==80) | .target_address' \
     <<<"$(cat "$FWDSTATE/forwards.json")")"

echo "== 3. and the reverse: reconciling Caddy must not take Forgejo's 22 away =="
reset_fwd
jq '.[0].ports += [{"protocol":"tcp","listen_port":22,"target_port":22,
                   "target_address":"10.0.0.101"}]' \
  <<<"$(live_forward)" >"$FWDSTATE/forwards.json"
: >"$CALLLOG"
sync_network_forward caddy "$CADDY_SPEC" 2>/dev/null
check "no removals at all" "0" "$(grep -c 'port remove' "$CALLLOG")"
check "ports now" "22,80,443" "$(ports_now)"

echo "== 4. a port no instance claims any more IS removed =="
# Otherwise the union degenerates into never removing anything.
#
# The withdrawal has to go in the REGISTRY, not in the spec passed as the
# argument. The argument is read only for the early-return checks and for the
# forward's own network/listen/target; the port union comes from
# incusInstances, so a fixture handed over as an argument contributes nothing to
# it. Passing a modified spec and expecting the union to follow is how this test
# first failed -- and the failure looked exactly like a reconciler ignoring a
# declaration, which is the opposite of what it was.
WITHDRAWN=$(jq -c '.networkForward.ports = [{"protocol":"tcp","listenPort":8443}]' \
  <<<"$CADDY_SPEC")
INSTANCES_JSON="$(jq -nc --argjson c "$WITHDRAWN" --argjson f "$FORGEJO_SPEC" \
  '{caddy:$c, forgejo:$f}')"
export INSTANCES_JSON
reset_fwd
sync_network_forward caddy "$WITHDRAWN" 2>/dev/null
check "443 removed"    "1" "$(grep -c 'port remove .* tcp 443$' "$CALLLOG")"
check "80 removed"     "1" "$(grep -c 'port remove .* tcp 80$' "$CALLLOG")"
check "22 kept"        "0" "$(grep -c 'port remove .* tcp 22$' "$CALLLOG")"
check "8443 added"     "1" "$(grep -c 'port add .* tcp 8443 ' "$CALLLOG")"
check "ports now" "22,8443" "$(ports_now)"
INSTANCES_JSON="$(jq -nc --argjson c "$CADDY_SPEC" --argjson f "$FORGEJO_SPEC" \
  '{caddy:$c, forgejo:$f}')"
export INSTANCES_JSON

echo "== 5. an already-converged forward is a pure no-op =="
reset_fwd
sync_network_forward forgejo "$FORGEJO_SPEC" 2>/dev/null   # adds 22
: >"$CALLLOG"
sync_network_forward forgejo "$FORGEJO_SPEC" 2>/dev/null
check_empty "second run wrote nothing"

echo "== 6. an unreadable registry must NOT be read as 'nobody declares anything' =="
# The dangerous failure, and the one this suite was written for. flake_instances
# dies, the union comes back empty, and the removal loop -- which runs first,
# deliberately -- deletes 80 and 443. So it has to die before any mutation, and
# the way to die has to be one the caller can see.
reset_fwd
NIX_BROKEN=1
# ( union ) -- the parentheses are load-bearing. die() calls exit, so calling
# union bare would take the whole test script down with it and the suite would
# stop dead at this line with no output and a success-looking status. Two of the
# earlier versions of this test did exactly that.
if ( union ) >/dev/null 2>&1; then
  printf '  FAIL forward_declarations returned successfully with no registry\n'
  fails=$((fails + 1))
else
  printf '  ok   forward_declarations fails\n'
fi
CALLLOG=$(mktemp); export CALLLOG; : >"$CALLLOG"
NIX_BROKEN=1
if ( sync_network_forward forgejo "$FORGEJO_SPEC" ) >/dev/null 2>&1; then
  printf '  FAIL sync_network_forward returned successfully with no registry\n'
  fails=$((fails + 1))
else
  printf '  ok   sync_network_forward fails rather than reporting success\n'
fi
check_empty "and mutates nothing before dying"
check "ports untouched" "80,443" "$(ports_now)"
NIX_BROKEN=""

echo "== 6a. an empty union with ports present is refused, and says WHICH case =="
# Distinct from 6, and the distinction is the whole point of this test.
#
# Test 6 uses an unreadable registry, which dies inside forward_declarations. Test
# 6a must use a registry that reads FINE and simply has no instance claiming this
# listen address -- otherwise it dies at the same guard as 6 and proves nothing
# about the empty-union guard. Two mutations, one per guard, and with an
# overlapping fixture each one masked the other: a mutation check found that
# removing EITHER guard alone still left this suite green.
#
# So: an instance in the registry, on a DIFFERENT address, so the union for this
# address is legitimately empty while ports exist here.
ELSEWHERE=$(jq -c '.networkForward.listenAddress = "10.9.9.9"' <<<"$CADDY_SPEC")
reset_fwd
INSTANCES_JSON="$(jq -nc --argjson o "$ELSEWHERE" '{elsewhere:$o}')"
export INSTANCES_JSON
diag=$( ( sync_network_forward forgejo "$FORGEJO_SPEC" ) 2>&1 ); rc=$?
check "non-zero" "1" "$((rc != 0))"
check "names the empty union, not the registry" "1" \
  "$(grep -c 'no instance declares any port' <<<"$diag")"
check "does not blame the registry" "0" \
  "$(grep -c 'cannot read incusInstances' <<<"$diag")"
check_empty "mutates nothing"
check "ports untouched" "80,443" "$(ports_now)"

echo "== 6b. an unreadable registry is reported AS an unreadable registry =="
# The other half of the pair: this is the diagnostic that distinguishes the two
# guards. With only the empty-union guard, an unreadable registry produces "no
# instance declares any port" -- which sends whoever reads the log looking for a
# port declaration problem instead of a broken flake read.
reset_fwd
INSTANCES_JSON="$(jq -nc --argjson c "$CADDY_SPEC" --argjson f "$FORGEJO_SPEC" \
  '{caddy:$c, forgejo:$f}')"
export INSTANCES_JSON
NIX_BROKEN=1
diag=$( ( sync_network_forward forgejo "$FORGEJO_SPEC" ) 2>&1 ); rc=$?
NIX_BROKEN=""
check "non-zero" "1" "$((rc != 0))"
check "blames the registry read" "1" \
  "$(grep -c 'cannot read the declared forwards' <<<"$diag")"
INSTANCES_JSON="$(jq -nc --argjson c "$CADDY_SPEC" --argjson f "$FORGEJO_SPEC" \
  '{caddy:$c, forgejo:$f}')"; export INSTANCES_JSON

echo "== 7. instances on a different listen address do not contribute =="
# Otherwise a second public address silently inherits another address's ports.
OTHER=$(jq -c '.networkForward.listenAddress = "10.9.9.9"' <<<"$CADDY_SPEC")
INSTANCES_JSON="$(jq -nc --argjson c "$CADDY_SPEC" --argjson f "$FORGEJO_SPEC" --argjson o "$OTHER" \
  '{caddy:$c, forgejo:$f, elsewhere:$o}')"
export INSTANCES_JSON
check "still just the two" "$want_lines" "$(union)"

echo "== 8. duplicate declarations are deduplicated =="
# in_list is exact-match, so a duplicate would otherwise read as a port to
# remove and re-add on every run -- a permanent write, every fifteen minutes.
INSTANCES_JSON="$(jq -nc --argjson c "$CADDY_SPEC" --argjson f "$FORGEJO_SPEC" \
  '{caddy:$c, forgejo:$f, forgejo2:$f}')"
export INSTANCES_JSON
mapfile -t got <<<"$(union)"
check "no duplicates" "3" "${#got[@]}"
INSTANCES_JSON="$(jq -nc --argjson c "$CADDY_SPEC" --argjson f "$FORGEJO_SPEC" \
  '{caddy:$c, forgejo:$f}')"
export INSTANCES_JSON

echo "== 9. a spec with no networkForward is a no-op, never a removal =="
reset_fwd
BARE='{"devices":{"eth0":{"type":"nic","network":"incusbr0"}}}'
sync_network_forward bare "$BARE" 2>/dev/null
check_empty "nothing called"

echo "== 10. a declared forward with no listen address is refused =="
# Not a removal: dropping networkForward from a spec does not take the DNAT away,
# and repointing a public entry point should stay a deliberate incus command
# rather than a side effect of editing a spec.
reset_fwd
BROKEN=$(jq -c '.networkForward.listenAddress = ""' <<<"$FORGEJO_SPEC")
if sync_network_forward broken "$BROKEN" >/dev/null 2>&1; then
  printf '  ok   returns quietly\n'
else
  printf '  FAIL died on a spec that simply declares no forward\n'
  fails=$((fails + 1))
fi
check_empty "nothing called at all"

echo "== 11. report_existing_drift must report the UNION, not one instance's list =="
# The reporter is the last check before the fifteen-minute unattended reconcile,
# so it has to agree with sync_network_forward exactly. It did not, and it failed
# in the loudest possible direction: on the live host, reconciling forgejo
# printed
#
#   forward .../tcp 22 22 10.0.0.101 (want)
#   forward .../tcp 80 80 10.0.0.100 (have, not declared)
#   forward .../tcp 443 443 10.0.0.100 (have, not declared)
#
# announcing the removal of Caddy's public entry points, on a forward that is
# completely correct. Only a --check dry run against the real Incus found this;
# the reconciler itself was already fixed and correct.
#
# The reporter reads the same state the reconciler does, so the stub state is the
# live forward: 80 and 443 present, 22 to be added.
reset_fwd
# Four arguments: name, spec, build_path, old_fingerprint.
report() { # name spec -> forward lines only
  report_existing_drift "$1" "$2" /nix/store/fake-image 40cc71975008 2>&1 \
    | grep 'forward '
}
out=$(report forgejo "$FORGEJO_SPEC")
check "no phantom removals" "0" "$(grep -c 'not declared' <<<"$out")"
check "does report 22 wanted" "1" "$(grep -c 'tcp 22 22 10.0.0.101 (want)' <<<"$out")"

# The check above is only meaningful if the reporter actually ran. It exits
# silently on the first unbound global, which produces the same empty output as a
# correct report -- so a passing "no phantom removals" is exactly what a reporter
# that never reached the forward would also produce. Hence the positive assertion,
# and hence this one.
check "the reporter ran at all" "1" "$(grep -c '(want)' <<<"$out")"

echo "== 11a. and the reverse: reconciling Caddy must not call 22 undeclared =="
reset_fwd
jq '.[0].ports += [{"protocol":"tcp","listen_port":22,"target_port":22,
                   "target_address":"10.0.0.101"}]' \
  <<<"$(live_forward)" >"$FWDSTATE/forwards.json"
out=$(report caddy "$CADDY_SPEC")
check "nothing undeclared" "0" "$(grep -c 'not declared' <<<"$out")"
check "nothing wanted"     "0" "$(grep -c '(want)' <<<"$out")"

echo "== 12. a forward with no nic, or no targetAddress, is refused LOUDLY =="
# These two are the ones that must not pass silently: both mean the spec is
# half-written, and both used to be reachable as a half-configured forward.
# The diagnostic is asserted because a die() that says nothing is as useless as
# no die() at all -- it is stderr, so it has to be captured, not left in a log.
reset_fwd
NONIC=$(jq -c 'del(.devices)' <<<"$FORGEJO_SPEC")
diag=$(sync_network_forward nonic "$NONIC" 2>&1 >/dev/null); rc=$?
check "no nic: non-zero"        "1" "$((rc != 0))"
check "no nic: says why"        "1" "$(grep -c 'no nic device names a network' <<<"$diag")"
check_empty "no nic: nothing called"

reset_fwd
NOTGT=$(jq -c 'del(.networkForward.targetAddress)' <<<"$FORGEJO_SPEC")
diag=$(sync_network_forward notgt "$NOTGT" 2>&1 >/dev/null); rc=$?
check "no target: non-zero"     "1" "$((rc != 0))"
check "no target: says why"     "1" "$(grep -c 'no targetAddress' <<<"$diag")"
check_empty "no target: nothing called"

echo
if [[ $fails -eq 0 ]]; then
  echo "all checks passed"
else
  echo "$fails check(s) FAILED"
fi
exit $((fails > 0))
