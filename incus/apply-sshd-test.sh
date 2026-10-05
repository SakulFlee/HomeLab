#!/usr/bin/env bash
# Tests for the guest's git transport, in incus/apply-sshd-test.sh.
#
# Different in kind from the other suites: those test apply.sh against stubs. This
# builds the guest and inspects the artefacts, because the bugs here were never
# logic errors. They were PATHS, and each one looked correct until the host said
# otherwise:
#
#   1. The store path.
#        error: Unsafe AuthorizedKeysCommand ".../forgejo-ssh-keys":
#               bad ownership or modes for directory /nix/store
#      /nix/store is drwxrwxr-t root:nixbld. The group write is the problem.
#
#   2. /etc/ssh/forgejo-ssh-keys via environment.etc. This one is the instructive
#      failure, because it PASSES a lexical check:
#
#        /etc            drwxr-xr-x root:root
#        /etc/ssh        drwxr-xr-x root:root
#
#      and the deployed guest showed exactly that chain -- and still failed.
#      NixOS installs environment.etc entries as symlinks:
#
#        /etc/ssh/forgejo-ssh-keys -> /etc/static/ssh/forgejo-ssh-keys
#                                    -> /nix/store/...-forgejo-ssh-keys
#
#      and auth_secure_path resolves the link before walking up, so it reaches
#      /nix/store anyway. I reasoned that it walked the LEXICAL path, wrote that
#      into a comment as though it were verified, and deployed on it.
#
# So this suite resolves the path the way sshd does -- realpath, then every
# ancestor -- and asserts on THAT. A lexical check is not a weaker version of the
# right check; it is the wrong check, and it is what let fix 2 through.
#
# The install target is /run and a real file, so there is no symlink to resolve at
# runtime. In a build tree /run does not exist, so the runtime half is asserted
# structurally: the unit exists, it is ordered before sshd, and its ExecStart is a
# copy rather than a symlink.
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
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

nixq() {
  if [[ -n ${NIX_SUDO:-} ]]; then
    sudo -n env HOME=/root PATH=/run/current-system/sw/bin:$PATH \
      nix --extra-experimental-features 'nix-command flakes' "$@"
  else
    nix --extra-experimental-features 'nix-command flakes' "$@"
  fi
}

# Every ancestor of a path must be root-owned and not group- or other-writable.
# This is auth_secure_path's rule, applied to a realpath.
chain_is_safe() { # path-under-root
  local p=$1 dir unsafe=""
  while [[ -n $p && $p != / ]]; do
    [[ -d $p ]] || { unsafe="$unsafe $p(absent)"; break; }
    local m o
    m=$(stat -c '%a' "$p" 2>/dev/null) || { unsafe="$unsafe $p(unreadable)"; break; }
    o=$(stat -c '%U' "$p" 2>/dev/null)
    (( 8#$m & 0022 )) && unsafe="$unsafe $p($m)"
    [[ $o == root ]] || unsafe="$unsafe $p(owner=$o)"
    p=$(dirname "$p")
  done
  printf '%s' "$unsafe"
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
echo "== 2. what AuthorizedKeysCommand names =="
cmdline=$(grep -E '^AuthorizedKeysCommand[[:space:]]' "$SSHD_CONFIG" | head -1)
echo "  $cmdline"
cmd=$(printf '%s' "$cmdline" | awk '{print $2}')
case $cmd in
  /nix/store/*)
    bad "names /nix/store, which is drwxrwxr-t root:nixbld -- sshd refuses it outright"
    ;;
  /etc/*)
    bad "names a path under /etc. NixOS installs those as symlinks into"
    echo "       /etc/static and on into /nix/store, so auth_secure_path resolves"
    echo "       straight back to the store. This LOOKS safe on a lexical check and"
    echo "       failed on the host for exactly that reason."
    ;;
  /run/*)
    ok "under /run -- not the store, and not a symlink into it" ;;
  *)
    bad "unexpected location: $cmd" ;;
esac

echo
echo "== 3. the resolved path's ancestor chain =="
# Only meaningful if the path exists here. It does not: it lives in the guest's
# /run, which is tmpfs and created at boot by the unit in check 6.
#
# Checking THIS machine's /run instead would be worse than useless -- it is
# drwxrwxrwt (1777, world-writable with a sticky bit), which is not what the
# guest's /run is, and the guest's was verified as drwxr-xr-x root:root. A test
# that passed here would be asserting something unrelated.
if [[ -e $cmd || -L $cmd ]]; then
  resolved=$(readlink -f "$cmd")
  printf '  %s -> %s\n' "$cmd" "$resolved"
  unsafe=$(chain_is_safe "$resolved")
  if [[ -n $unsafe ]]; then
    bad "group/other-writable or non-root in the resolved chain:$unsafe"
  else
    ok "every ancestor is root-owned and unwritable by group/other"
  fi
else
  printf '  skip  %s is created at boot, so its chain cannot be checked\n' "$cmd"
  printf '        from a build tree. Covered structurally in check 6, and the\n'
  printf '        guest side (/run drwxr-xr-x root:root) has been verified on the\n'
  printf '        host -- twice, each time after a wrong fix had already shipped.\n'
fi

echo
echo "== 4. negative control: /etc entries really do resolve into the store =="
# This is the whole reason /run is used, so the control must run against something
# that exists. /etc/ssh/sshd_config is installed by the same mechanism
# environment.etc uses, so it demonstrates the property without depending on the
# entry that was removed.
#
# Uses sshd_config rather than the old forgejo-ssh-keys symlink, which no longer
# exists precisely because it was the wrong fix.
probe="$GUEST/etc/ssh/sshd_config"
if [[ -L $probe ]]; then
  target=$(readlink -f "$probe")
  printf '  /etc/ssh/sshd_config -> %s\n' "$target"
  case $target in
    /nix/store/*)
      ok "an /etc entry resolves into /nix/store, so /etc can never be safe here" ;;
    *)
      bad "expected /etc/ssh/sshd_config to resolve into the store, but it does not."
      echo "       If NixOS changed how it installs /etc, re-derive the /run choice." ;;
  esac
else
  bad "/etc/ssh/sshd_config is not a symlink in the built guest, so the control"
  echo "       cannot run and nothing here is being proved."
fi

echo
echo "== 5. /nix/store really is group-writable here =="
store=${NIX_STORE_DIR:-/nix/store}
perm=$(stat -c '%a' "$store" 2>/dev/null)
printf '  %s is %s\n' "$store" "$perm"
if [[ -n $perm ]] && (( 8#$perm & 0022 )); then
  ok "group-writable, as sshd sees it -- the checks above are real"
else
  bad "not group-writable here; the checks above would prove nothing"
fi

echo
echo "== 6. the install unit exists and is ordered before sshd =="
UNIT="$GUEST/etc/systemd/system/forgejo-ssh-keys-install.service"
if [[ -f $UNIT ]]; then
  ok "forgejo-ssh-keys-install.service is in the built guest"
  grep -q 'Before=sshd' "$UNIT" \
    && ok "ordered Before=sshd.service" \
    || { bad "no Before=sshd.service -- sshd could start before the script exists"; }
  grep -qE 'WantedBy=.*sshd' "$UNIT" \
    && ok "wanted by sshd.service, so it does not depend on anything else pulling it in" \
    || bad "not WantedBy=sshd.service"
  grep -q 'RuntimeDirectory=forgejo-ssh-keys' "$UNIT" \
    && ok "creates its own directory under /run, 0755" \
    || bad "no RuntimeDirectory -- the directory would have to be made by hand"
  # A COPY, not a symlink. `ln -s` here would resolve to the store and reintroduce
  # exactly the bug this file exists to prevent.
  if grep -qE 'ExecStart=.*\binstall\b.* -m ' "$UNIT"; then
    ok "ExecStart copies the script (install -m), it does not symlink it"
  elif grep -qE 'ExecStart=.*\bln\b' "$UNIT"; then
    bad "ExecStart creates a SYMLINK -- that resolves back into /nix/store"
  else
    bad "ExecStart does not look like a copy"
  fi
  # And the destination must be the path sshd actually reads.
  grep -q "$cmd" "$UNIT" \
    && ok "writes to the path sshd_config names" \
    || { bad "ExecStart does not write to $cmd"; }
else
  bad "forgejo-ssh-keys-install.service is missing -- sshd would name a file"
  echo "       that only exists if something creates it by hand."
fi

echo
echo "== 7. the rest of the transport, unchanged =="
for want in \
  'Port 22' \
  'AuthorizedKeysCommandUser root' \
  'AuthenticationMethods publickey' \
  'PermitRootLogin no' \
  'PasswordAuthentication no' \
  'PermitTTY no' \
  'AllowTcpForwarding no'
do
  if grep -qxF "$want" "$SSHD_CONFIG"; then ok "$want"
  else bad "missing: $want"; fi
done
check "exactly one Port directive" "1" "$(grep -cE '^Port ' "$SSHD_CONFIG")"

echo
echo "== 8. the key script itself =="
# Take it from the install unit's ExecStart, i.e. what actually gets copied.
script=$(grep -oE '/nix/store/[^ ]*-forgejo-ssh-keys' "$UNIT" 2>/dev/null | head -1)
if [[ -n $script && -f $script ]]; then
  bash -n "$script" && ok "parses" || bad "does not parse"
  grep -q 'runuser -u forgejo' "$script" \
    && ok "drops to forgejo before querying (peer auth matches the OS user)" \
    || bad "queries the database without dropping privileges"
  grep -qF 'command="%s serv key-%s --config %s"' "$script" \
    && ok "emits the key- prefix serv requires" \
    || bad "the forced command does not carry the key- prefix"
else
  bad "could not find the script the install unit copies"
fi

echo
echo "== 9. every ExecStart in the guest resolves to a real executable =="
# Three separate bugs in this change were a string that LOOKED right and named a
# path the filesystem disagreed with:
#
#   AuthorizedKeysCommand ${keySource}        -> /nix/store is 1775, refused
#   AuthorizedKeysCommand /etc/ssh/...         -> symlink into /nix/store, refused
#   ExecStart "${configAccessScript}/bin/..."  -> the script is a FILE; 203/EXEC
#
# All three passed review and every static check, and all three were found on the
# host. The third is what this check is for, and it generalises: resolve each
# ExecStart against the built closure and require an executable file. A miss is
# reported rather than skipped, because "not in the closure" IS the failure mode.
# -L is required, not optional: the guest's /etc is a SYMLINK to the etc
# derivation, so a plain find does not descend, this check examined zero files,
# and it passed. The floor below is the other half of that -- a check that
# examines nothing has proved nothing, and "0 bad" over an empty set looks
# exactly like a pass.
units=0; checked=0; badunits=0
while IFS= read -r unit; do
  units=$((units + 1))
  # ExecStart may be a list; take the first word of the first element.
  exe=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$unit" | head -1)
  [[ -n $exe ]] || continue
  case $exe in
    /*) ;;
    *) continue ;;                        # a systemd keyword, not a path
  esac
  checked=$((checked + 1))
  if [[ -f $exe && -x $exe ]]; then
    :
  else
    badunits=$((badunits + 1))
    printf '  FAIL %s\n' "${unit#$GUEST/etc/systemd/system/}"
    printf '         ExecStart=%s\n' "$exe"
    if [[ -e $exe ]]; then
      printf '         -> exists but is not an executable file\n'
    else
      printf '         -> does not exist in the closure\n'
    fi
  fi
done < <(find -L "$GUEST/etc/systemd/system" -name '*.service' -type f 2>/dev/null)
check "absolute ExecStarts that resolve" "0" "$badunits"
if [[ $checked -lt 50 ]]; then
  bad "only $checked ExecStart(s) examined -- the traversal is broken, not the units"
else
  ok "examined $checked absolute ExecStart(s) across $units units"
fi

echo
echo "== 10. sshd -t accepts the config =="
SSHD=$(grep -oE '/nix/store/[^ ]*/bin/sshd' "$SSHD_CONFIG" | head -1)
if [[ -x $SSHD ]]; then
  if out=$("$SSHD" -t -f "$SSHD_CONFIG" 2>&1); then ok "sshd -t accepts it"
  else bad "sshd -t:"; printf '%s\n' "$out" | sed 's/^/       /'; fi
else
  printf '  skip (sshd not at a findable path in the closure)\n'
fi

echo
if [[ $fails -eq 0 ]]; then echo "all checks passed"; else echo "$fails check(s) FAILED"; fi
exit $((fails > 0))
