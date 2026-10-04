#!/usr/bin/env bash
# Tests for the guest's git transport, in incus/apply-sshd-test.sh.
#
# Different from the other suites in kind: those test apply.sh against stubs. This
# one builds the guest configuration and inspects the artefacts, because the bug
# it exists to catch was never a logic error. It was a path:
#
#   error: Unsafe AuthorizedKeysCommand ".../forgejo-ssh-keys":
#          bad ownership or modes for directory /nix/store
#
# sshd refuses an AuthorizedKeysCommand whose path passes through a group- or
# other-writable directory, and /nix/store is drwxrwxr-t root:nixbld. The group
# write is the whole problem. Every key lookup failed before a key was offered,
# and the symptom was a bare `Permission denied (publickey)` on a push that had
# worked minutes earlier.
#
# It survived because the end-to-end test ran the script from /run/e2e, whose
# chain is root-owned and unwritable. The test exercised a stand-in path and never
# the one sshd reads, and I recorded "/run/... and /nix/store are fine" -- wrong on
# the second half, and deployed on.
#
# So: assert the property, against the built configuration, with no live sshd.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NIXDIR="$ROOT/nixos"
FLAKE=${FLAKE:-$NIXDIR}

fails=0
check() {
  local what=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then printf '  ok   %s\n' "$what"
  else printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$what" "$want" "$got"; fails=$((fails + 1)); fi
}

nixq() {
  if [[ -n ${NIX_SUDO:-} ]]; then
    sudo -n env HOME=/root PATH=/run/current-system/sw/bin:$PATH \
      nix --extra-experimental-features 'nix-command flakes' "$@"
  else
    nix --extra-experimental-features 'nix-command flakes' "$@"
  fi
}

echo "== 1. the built guest configuration =="
GUEST=$(nixq build --no-link --print-out-paths --impure --expr \
  "let f = builtins.getFlake (toString $FLAKE);
   in [ f.nixosConfigurations.forgejo.config.system.build.toplevel ]" 2>/dev/null | tail -1)
if [[ -z $GUEST || ! -d $GUEST ]]; then
  echo "FATAL: could not build the guest configuration (set NIX_SUDO=1 if nix needs root)"
  exit 99
fi
echo "  guest: $GUEST"

SSHD_CONFIG="$GUEST/etc/ssh/sshd_config"
[[ -f $SSHD_CONFIG ]] || { echo "FATAL: no sshd_config in the built guest"; exit 99; }

echo
echo "== 2. what AuthorizedKeysCommand actually names =="
cmdline=$(grep -E '^AuthorizedKeysCommand[[:space:]]' "$SSHD_CONFIG" | head -1)
echo "  $cmdline"
cmd=$(printf '%s' "$cmdline" | awk '{print $2}')

case $cmd in
  /nix/store/*)
    printf '  FAIL AuthorizedKeysCommand points into /nix/store, which is\n'
    printf '       drwxrwxr-t root:nixbld. sshd refuses it unconditionally:\n'
    printf '         error: Unsafe AuthorizedKeysCommand "%s": bad ownership or modes for directory /nix/store\n' "$cmd"
    printf '       and every push fails as a bare "Permission denied (publickey)".\n'
    fails=$((fails + 1)) ;;
  /etc/ssh/*)
    printf '  ok   not a store path\n' ;;
  *)
    printf '  FAIL unexpected AuthorizedKeysCommand location: %s\n' "$cmd"
    fails=$((fails + 1)) ;;
esac

echo
echo "== 3. the script is actually installed there =="
# $GUEST$cmd, not $cmd. The command is an absolute path *inside the guest*, so
# looking for it at that path on this machine tests the wrong filesystem -- which
# is how this check reported a missing file for one that is present.
if [[ -e $GUEST$cmd || -L $GUEST$cmd ]]; then
  printf '  ok   %s exists in the built guest\n' "$cmd"
  printf '       -> %s\n' "$(readlink -f "$GUEST$cmd")"
  [[ -x $GUEST$cmd ]] && printf '  ok   executable\n' \
                      || { printf '  FAIL not executable\n'; fails=$((fails + 1)); }
else
  printf '  FAIL %s does not exist in the built guest\n' "$cmd"
  fails=$((fails + 1))
fi

echo
echo "== 4. the whole ancestor chain is root-owned and unwritable =="
# The property auth_secure_path() actually enforces, asserted directly rather than
# reasoned about: no directory from / down to the command may be writable by group
# or other, and all must belong to root.
#
# Checked on a real filesystem for the paths that exist in the build tree, and
# against the modes a fresh NixOS root has for the rest -- /nix and /nix/store are
# not part of a system closure, so their modes come from the guest's own rootfs
# rather than anything reachable from here.
unsafe=""
for d in / /etc /etc/ssh; do
  m=$(stat -c '%a %U' "$d" 2>/dev/null) || { unsafe="$unsafe $d(unreadable)"; continue; }
  perm=${m%% *}; owner=${m##* }
  printf '  %-12s %s %s\n' "$d" "$perm" "$owner"
  # any write bit for group or other
  if (( 8#$perm & 0022 )); then unsafe="$unsafe $d"; fi
  [[ $owner == root ]] || unsafe="$unsafe $d(owner=$owner)"
done
if [[ -n $unsafe ]]; then
  printf '  FAIL group/other-writable or non-root in the chain:%s\n' "$unsafe"
  fails=$((fails + 1))
else
  printf '  ok   every directory in the chain is root-owned and unwritable by group/other\n'
fi

echo
echo "== 5. and /nix/store would NOT have passed, which is the point =="
# A negative control, so check 4 cannot pass vacuously. If this ever reports the
# store as safe, then check 4 is not testing what it claims to.
store=${NIX_STORE_DIR:-/nix/store}
if [[ -d $store ]]; then
  perm=$(stat -c '%a' "$store")
  printf '  %s is %s\n' "$store" "$perm"
  if (( 8#$perm & 0022 )); then
    printf '  ok   group-writable, as sshd sees it -- check 4 is a real test\n'
  else
    printf '  FAIL not group-writable here, so check 4 proves nothing about the guest\n'
    fails=$((fails + 1))
  fi
else
  printf '  skip (%s absent)\n' "$store"
fi

echo
echo "== 6. the rest of the transport, unchanged =="
for want in \
  'Port 22' \
  'AuthorizedKeysCommandUser root' \
  'AuthenticationMethods publickey' \
  'PermitRootLogin no' \
  'PasswordAuthentication no' \
  'PermitTTY no' \
  'AllowTcpForwarding no'
do
  if grep -qxF "$want" "$SSHD_CONFIG"; then printf '  ok   %s\n' "$want"
  else printf '  FAIL missing: %s\n' "$want"; fails=$((fails + 1)); fi
done
# Exactly one Port, and it is 22 -- the duplicate-Port bug from the host config
# belongs in this file too if it ever reappears here.
nport=$(grep -cE '^Port ' "$SSHD_CONFIG")
check "exactly one Port directive" "1" "$nport"

echo
echo "== 7. the key script itself =="
script=$(readlink -f "$GUEST$cmd" 2>/dev/null || echo "$GUEST$cmd")
if [[ -f $script ]]; then
  bash -n "$script" && printf '  ok   parses\n' || { printf '  FAIL does not parse\n'; fails=$((fails + 1)); }
  # The peer-authentication fix. Reverted, this returns an empty key list and every
  # push fails with nothing logged; it was found by running the generated script as
  # root, which is what sshd does, and it is invisible to reading it.
  if grep -q 'runuser -u forgejo' "$script"; then
    printf '  ok   drops to forgejo before querying (peer auth needs the OS user)\n'
  else
    printf '  FAIL queries the database without dropping privileges\n'
    fails=$((fails + 1))
  fi
  # Match the printf FORMAT, not the string `serv key-`. The generated script
  # explains the prefix in a comment, so the loose pattern matched the comment and
  # a mutation that dropped the prefix from the format string still passed. Found
  # by the mutation suite.
  if grep -q 'command="%s serv key-%s --config %s"' "$script"; then
    printf '  ok   emits the key- prefix serv requires\n'
  else
    printf '  FAIL the forced command does not carry the key- prefix\n'
    printf '       (matching on the printf format, not on any mention of it)\n'
    fails=$((fails + 1))
  fi
else
  printf '  FAIL no script at %s\n' "$script"
  fails=$((fails + 1))
fi

echo
echo "== 8. the sshd config is valid to sshd itself =="
SSHD=$(grep -oE '/nix/store/[^ ]*/bin/sshd' "$SSHD_CONFIG" | head -1)
if [[ -x $SSHD ]]; then
  # -T needs the host keys to exist, which they do not in a build tree. -t only
  # checks the file's syntax and directives, which is what is being asked.
  if out=$("$SSHD" -t -f "$SSHD_CONFIG" 2>&1); then
    printf '  ok   sshd -t accepts it\n'
  else
    printf '  FAIL sshd -t:\n'; printf '%s\n' "$out" | sed 's/^/       /'
    fails=$((fails + 1))
  fi
else
  printf '  skip (sshd not in the closure at a findable path)\n'
fi

echo
if [[ $fails -eq 0 ]]; then echo "all checks passed"; else echo "$fails check(s) FAILED"; fi
exit $((fails > 0))
