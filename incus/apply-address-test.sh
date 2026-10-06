#!/usr/bin/env bash
# Tests for instance_address in incus/apply.sh. Run it: ./incus/apply-address-test.sh
#
# Pure bash against a stubbed `incus`, so it needs no Incus, no Nix and no root,
# and cannot touch a real instance.
#
# The function under test was wrong for every VM on this host, and invisibly so.
# It asked for `.state.network.eth0`, but `state.network` is keyed by the
# interface name the GUEST's kernel uses, and a VM's kernel renames eth0:
#
#   caddy          (container)  eth0, lo                       -> 10.0.0.100
#   wireguard      (vm)         enp5s0, enp6s0, lo, wg0        -> (nothing)
#   forgejo-runner (vm)         docker0, enp5s0, lo             -> (nothing)
#
# Nothing failed. wait_ready waited out its whole 60-iteration budget and logged
# a warning that read like a slow boot:
#
#   WARN: forgejo-runner had no address on eth0 after 60s (status: Running)
#
# while the guest's own journal showed incus-agent started and enp5s0 configured
# 15 seconds after `incus start`. The address was there the whole time. The
# closing summary said "ok -- Running" with no address, and wait_ready never
# confirmed the one thing it exists to confirm -- which is the failure the
# pinned hwaddr in incus.nix exists to prevent.
#
# The fixtures below are the shapes measured above, reduced to the fields the
# function reads. The cases that matter most are the two that are easy to get
# wrong in the other direction: matching an absent MAC against "" picks `lo` and
# reports 127.0.0.1, and `state.network` is null early in a boot, when
# wait_ready is polling -- so an unguarded `to_entries` aborts apply.sh under
# its own `set -Eeuo pipefail`.
set -uo pipefail

APPLY=${APPLY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apply.sh}
[[ -f $APPLY ]] || { echo "FATAL: $APPLY not found"; exit 99; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fixtures"

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

# --- extract the function under test ----------------------------------------
START=$(grep -n '^instance_address()' "$APPLY" | cut -d: -f1)
[[ -n $START ]] || { echo "FATAL: could not locate instance_address in apply.sh"; exit 99; }
# The function is the last thing before the next top-level comment banner.
END=$(awk -v s="$START" 'NR > s && /^# ---/ { print NR; exit }' "$APPLY")
[[ -n $END ]] || { echo "FATAL: could not find the end of instance_address"; exit 99; }
sed -n "${START},$((END - 1))p" "$APPLY" >"$WORK/block.sh"
grep -q '^instance_address()' "$WORK/block.sh" \
  || { echo "FATAL: instance_address not in the extracted block"; exit 99; }

# incus_run is apply.sh's own logging wrapper and lives OUTSITE the extracted
# block. It is not what is under test, but it is what invokes the stub, so it
# has to be present and has to prepend `incus` -- a bare `"$@"` passthrough runs
# `list` as a command and every check fails with "list: command not found".
incus_run() { incus "$@"; }
# shellcheck source=/dev/null
source "$WORK/block.sh"

# --- the incus stub ----------------------------------------------------------
# One fixture per instance name, chosen by the name the function is given.
# `incus list <name> --format json` is the only call the function makes, and it
# gets the whole object -- expanded_devices and state together -- so the stub
# does not have to know which of the two the function reads.
#
# The name is the token AFTER `list`. Taking the first bare word instead picks up
# the verb, so every lookup resolves to a fixture called "list" and every check
# fails at once with "Instance not found" -- which looks like the function
# returning empty rather than like a broken stub, and the checks that expect
# empty then pass for the wrong reason.
cat >"$WORK/bin/incus" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
name=""
prev=""
for a in "$@"; do
  if [[ $prev == list ]]; then
    name=$a
    break
  fi
  prev=$a
done
f="$FIXTURES/$name.json"
[[ -f $f ]] || { echo "Error: Instance not found: $name" >&2; exit 1; }
cat "$f"
STUB
chmod +x "$WORK/bin/incus"

# fixture <name> <json>
fixture() { printf '%s' "$2" >"$WORK/fixtures/$1.json"; }

# The three shapes measured on the live host.
RUNNER_MAC=00:16:3e:00:00:12

fixture forgejo-runner "[{
  \"expanded_devices\": {\"eth0\": {\"type\":\"nic\",\"name\":\"eth0\",\"network\":\"incusbr0\",\"hwaddr\":\"$RUNNER_MAC\"}},
  \"state\": {\"network\": {
    \"docker0\": {\"hwaddr\":\"22:7e:c2:52:d6:21\",\"state\":\"down\",\"addresses\":[{\"family\":\"inet\",\"address\":\"172.17.0.1\"}]},
    \"enp5s0\":  {\"hwaddr\":\"$RUNNER_MAC\",\"state\":\"up\",\"host_name\":\"tap146b5119\",\"addresses\":[{\"family\":\"inet\",\"address\":\"10.0.0.102\",\"scope\":\"global\"},{\"family\":\"inet6\",\"address\":\"fe80::216:3eff:fe00:12\",\"scope\":\"link\"}]},
    \"lo\":      {\"hwaddr\":\"\",\"addresses\":[{\"family\":\"inet\",\"address\":\"127.0.0.1\"}]}
  }}
}]"

fixture wireguard "[{
  \"expanded_devices\": {
    \"eth0\": {\"type\":\"nic\",\"name\":\"eth0\",\"nictype\":\"macvlan\",\"parent\":\"eno1\",\"hwaddr\":\"00:16:3e:00:00:10\"},
    \"eth1\": {\"type\":\"nic\",\"name\":\"eth1\",\"network\":\"incusbr0\",\"hwaddr\":\"00:16:3e:00:00:11\"}
  },
  \"state\": {\"network\": {
    \"enp5s0\": {\"hwaddr\":\"00:16:3e:00:00:10\",\"addresses\":[{\"family\":\"inet\",\"address\":\"192.168.178.210\"}]},
    \"enp6s0\": {\"hwaddr\":\"00:16:3e:00:00:11\",\"addresses\":[{\"family\":\"inet\",\"address\":\"10.0.0.110\"}]},
    \"wg0\":    {\"hwaddr\":\"00:16:3e:00:00:20\",\"addresses\":[{\"family\":\"inet\",\"address\":\"100.64.0.1\"}]},
    \"lo\":     {\"hwaddr\":\"\",\"addresses\":[{\"family\":\"inet\",\"address\":\"127.0.0.1\"}]}
  }}
}]"

# A container: no pinned MAC anywhere on the device, and the interface really is
# named eth0 because a container shares the host kernel.
fixture caddy "[{
  \"expanded_devices\": {\"eth0\": {\"type\":\"nic\",\"name\":\"eth0\",\"network\":\"incusbr0\",\"ipv4.address\":\"10.0.0.100\"}},
  \"state\": {\"network\": {
    \"eth0\": {\"hwaddr\":\"10:66:6a:c9:9a:ea\",\"addresses\":[{\"family\":\"inet\",\"address\":\"10.0.0.100\"}]},
    \"lo\":   {\"hwaddr\":\"\",\"addresses\":[{\"family\":\"inet\",\"address\":\"127.0.0.1\"}]}
  }}
}]"

export FIXTURES="$WORK/fixtures"
export PATH="$WORK/bin:$PATH"

echo "== 1. the bug: a VM whose kernel renamed eth0 =="
check "forgejo-runner resolves to its address, not to nothing" \
  "10.0.0.102" "$(instance_address forgejo-runner)"
check "and specifically not to loopback" "no" \
  "$([[ $(instance_address forgejo-runner) == 127.0.0.1 ]] && echo yes || echo no)"

echo
echo "== 2. the MAC picks the interface, not the device's position =="
# eth0 here is a macvlan; the incusbr0 address lives on eth1. Joining on the MAC
# gets eth0's, which is what the function is asked for, and joining on nothing in
# particular would have got whichever came first.
check "wireguard's eth0 (macvlan) address" "192.168.178.210" "$(instance_address wireguard)"
check "and not eth1's" "no" \
  "$([[ $(instance_address wireguard) == 10.0.0.110 ]] && echo yes || echo no)"
check "and not the wg0 tunnel's" "no" \
  "$([[ $(instance_address wireguard) == 100.64.0.1 ]] && echo yes || echo no)"

echo
echo "== 3. a container with no pinned MAC falls back to the name =="
# Incus generates the MAC and only ever reports it under state.network, so the
# device carries no hwaddr to join on. Matching by name is what makes this work.
check "caddy still resolves" "10.0.0.100" "$(instance_address caddy)"

echo
echo "== 4. the fallback must not match lo =="
# Comparing an absent MAC against "" matches lo, whose hwaddr is also empty. This
# is the failure mode of the obvious one-line fix, and it looks like success.
fixture nolo "[{
  \"expanded_devices\": {\"eth0\": {\"type\":\"nic\",\"name\":\"eth0\",\"network\":\"incusbr0\"}},
  \"state\": {\"network\": {
    \"enp5s0\": {\"hwaddr\":\"aa:bb:cc:dd:ee:ff\",\"addresses\":[{\"family\":\"inet\",\"address\":\"10.0.0.102\"}]},
    \"lo\": {\"hwaddr\":\"\",\"addresses\":[{\"family\":\"inet\",\"address\":\"127.0.0.1\"}]}
  }}
}]"
# A VM with no pinned MAC: name fallback finds nothing, and must say so rather
# than hand back 127.0.0.1.
check "a VM with no pinned MAC reports nothing at all" "" "$(instance_address nolo)"
# A container with no pinned MAC must still find eth0 and not stop at lo, which
# sorts first.
fixture lofirst "[{
  \"expanded_devices\": {\"eth0\": {\"type\":\"nic\",\"name\":\"eth0\",\"network\":\"incusbr0\"}},
  \"state\": {\"network\": {
    \"lo\":   {\"hwaddr\":\"\",\"addresses\":[{\"family\":\"inet\",\"address\":\"127.0.0.1\"}]},
    \"eth0\": {\"hwaddr\":\"10:66:6a:c9:9a:ea\",\"addresses\":[{\"family\":\"inet\",\"address\":\"10.0.0.100\"}]}
  }}
}]"
check "lo listed first does not win" "10.0.0.100" "$(instance_address lofirst)"

echo
echo "== 5. degenerate shapes must not raise =="
# wait_ready polls this in a loop right after start, when state.network is
# routinely absent. Under apply.sh's own `set -Eeuo pipefail` a jq error here is
# not an empty answer, it is the whole script dying mid-reconcile.
fixture nonet '[{"state":{"network":null}}]'
check "state.network null"        "" "$(instance_address nonet 2>&1)"
check "  and it exits 0"          "0"  "$(instance_address nonet >/dev/null 2>&1; echo $?)"
fixture nostate '[{"state":null}]'
check "state null"                "" "$(instance_address nostate 2>&1)"
fixture nothing '[{}]'
check "no state at all"           "" "$(instance_address nothing 2>&1)"
fixture empty '[]'
check "empty list"                "" "$(instance_address empty 2>&1)"
fixture noaddr '[{"state":{"network":{"enp5s0":{"hwaddr":"aa:bb:cc:dd:ee:ff"}}}}]'
check "interface with no addresses" "" "$(instance_address noaddr 2>&1)"
fixture nulladdr '[{"state":{"network":{"eth0":{"hwaddr":"","addresses":null}}}}]'
check "addresses null"            "" "$(instance_address nulladdr 2>&1)"
fixture nomatch '[{"state":{"network":{"lo":{"hwaddr":"","addresses":[{"family":"inet","address":"127.0.0.1"}]}}}}]'
check "no interface matching the MAC" "" "$(instance_address nomatch 2>&1)"

echo
echo "== 6. address families and multiplicity =="
fixture v6only '[{"expanded_devices":{"eth0":{"type":"nic","name":"eth0"}},"state":{"network":{"eth0":{"hwaddr":"","addresses":[{"family":"inet6","address":"fe80::1"},{"family":"inet6","address":"2001:db8::1"}]}}}}]'
check "inet6 alone is not an address" "" "$(instance_address v6only 2>&1)"
fixture mixed '[{"expanded_devices":{"eth0":{"type":"nic","name":"eth0"}},"state":{"network":{"eth0":{"hwaddr":"","addresses":[{"family":"inet6","address":"fe80::1"},{"family":"inet","address":"10.0.0.100"}]}}}}]'
check "inet6 is filtered out of a mixed list" "10.0.0.100" "$(instance_address mixed 2>&1)"
fixture multi '[{"expanded_devices":{"eth0":{"type":"nic","name":"eth0"}},"state":{"network":{"eth0":{"hwaddr":"","addresses":[{"family":"inet","address":"10.0.0.100"},{"family":"inet","address":"10.0.0.101"}]}}}}]'
check "two addresses on one interface are both reported" \
  "10.0.0.100,10.0.0.101" "$(instance_address multi 2>&1)"

echo
echo "== 7. an unknown instance is an empty answer, not a crash =="
check "the stub's failure does not become output" "" "$(instance_address ghost 2>/dev/null)"

echo
if [[ $fails -eq 0 ]]; then
  echo "all checks passed"
else
  echo "$fails check(s) FAILED"
fi
exit $((fails > 0))
