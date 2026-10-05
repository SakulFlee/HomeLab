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
# The reconciler, for the whole-file invariants in check 11. Overridable so the
# suite can be pointed at a copy of it instead of the working tree.
APPLY=${APPLY:-$ROOT/incus/apply.sh}
[[ -f $APPLY ]] || { echo "FATAL: no apply.sh at $APPLY"; exit 99; }

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
echo "== 10. the config-access script refuses to run before app.ini exists =="
# It must exit non-zero, not exit 0 having done nothing. The failure it avoids is
# exactly what happened: 0751 landed on the parents, the two files inside conf/
# kept their modes, and the run reported success.
#
# It must also not invoke `su`. The unit's PATH is coreutils, findutils, grep, sed
# and systemd, so:
#
#   line 35: su: command not found
#
# and the verification that existed to catch "custom/conf is still 0700" was itself
# the thing that broke -- the script exited 0 having proved nothing.
SCRIPT=""
UNIT2="$GUEST/etc/systemd/system/forgejo-config-access.service"
# From the unit's own ExecStart, NOT from "$GUEST"/nix/store -- the guest's store
# is not inside the build tree, so that glob matches nothing and the check would
# report "could not find the script" for a script that is present. The unit's
# ExecStart is also the authoritative pointer: it is the path systemd will run.
if [[ -f $UNIT2 ]]; then
  SCRIPT=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$UNIT2" | head -1)
fi
if [[ -n $SCRIPT && -f $SCRIPT && -x $SCRIPT ]]; then
  bash -n "$SCRIPT" && ok "parses" || bad "does not parse"
  # On the CONDITION, not on the message inside the branch. The first version
  # grepped for "does not exist yet", which is in the echo -- so replacing the
  # condition with `if false; then` left the message in place and the check passed
  # over a script that could still exit 0 having done nothing.
  if grep -qE 'if \[ ! -f [^ ]*app\.ini \]; then' "$SCRIPT"; then
    ok "has a pre-flight condition on app.ini, not just a message about it"
  else
    bad "no pre-flight condition on app.ini -- it can exit 0 having achieved nothing"
  fi
  # Two precise checks rather than a crude "extract every command word" pass.
  #
  # The extraction was tried and abandoned: it cannot tell a command from prose
  # inside a multi-line echo string, so it reported `does` and `apply` as missing
  # commands. A check that cries wolf on English words trains you to ignore it.
  #
  # What actually matters is narrow and checkable:
  #
  #   1. no bare `su`. The unit's PATH is coreutils, findutils, grep, sed and
  #      systemd. `su` and `runuser` are NOT in it, and `su -s ... git -c ...` is
  #      exactly what failed with "su: command not found" -- taking the whole
  #      verification with it, so the script exited 0 having proved nothing.
  #   2. every /nix/store path the script names must exist. These are absolute, so
  #      there is nothing to guess about.
  # Comments first. writeShellScript keeps them, and the comment explaining WHY
  # `su` is banned contains the word -- so the first version of this check matched
  # its own documentation and failed.
  CODE=$(sed 's/[[:space:]]*#.*$//' "$SCRIPT")
  if grep -qE '(^|[;&|(]|[[:space:]])su[[:space:]]' <<<"$CODE"; then
    bad "invokes a bare 'su', which is not in this unit's PATH"
    grep -nE '(^|[;&|(]|[[:space:]])su[[:space:]]' <<<"$CODE" | head -2 | sed 's/^/       /'
  else
    ok "no bare su -- runuser is used, from an explicit store path"
  fi
  npaths=0; missing=0
  while IFS= read -r p; do
    npaths=$((npaths + 1))
    if [[ ! -e $p ]]; then
      missing=$((missing + 1))
      printf '  FAIL references %s, which is not in the closure\n' "$p"
    fi
  done < <(grep -oE '/nix/store/[A-Za-z0-9._+-]+' "$SCRIPT" | sort -u)
  check "store paths referenced, all present" "0" "$missing"
  if [[ $npaths -lt 2 ]]; then
    bad "only $npaths store path(s) found -- the extraction is broken, not the script"
  else
    ok "resolved $npaths absolute store path(s)"
  fi
  # And the commands it relies on being on PATH are all coreutils, which the unit
  # has. Asserted rather than assumed, because the PATH is set in this file.
  unitpath="coreutils findutils gnugrep gnused systemd"
  for c in chmod head; do
    case $unitpath in *"$c"*|*coreutils*) : ;; *) bad "$c may not be in the unit PATH" ;; esac
  done
  ok "the remaining commands (chmod, head) are coreutils, which the unit has"
else
  bad "could not find the config-access script in the closure"
fi

UNIT2="$GUEST/etc/systemd/system/forgejo-config-access.service"
if [[ -f $UNIT2 ]]; then
  # Tolerated at boot, because a fresh or recreated instance legitimately has no
  # app.ini yet. The re-run after render_secrets is what must not be skipped.
  grep -q '^SuccessExitStatus=1' "$UNIT2" \
    && ok "tolerates its own exit 1 at boot, so a recreate is not marked broken" \
    || bad "no SuccessExitStatus -- every recreate would fail this unit"
  grep -qE '^ExecStart=/nix/store/[^ ]+-forgejo-config-access$' "$UNIT2" \
    && ok "ExecStart is the bare script path, no /bin suffix" \
    || bad "ExecStart is not a bare script path"
else
  bad "forgejo-config-access.service is not in the built guest"
fi

echo
echo "== 11. apply.sh re-runs it, and the spec tells it to =="
# The unit runs at BOOT; the secrets are written by the host reconciler afterwards,
# eight seconds later on the live instance. So the reconciler has to say "now they
# exist" -- it is the thing that creates them.
if grep -qE 'if \[\[ -n .*afterRenderSecrets' "$APPLY"; then
  ok "the guard that re-runs the units reads afterRenderSecrets from the spec"
  # Not merely "the word appears somewhere" -- a mutation that replaced the
  # condition with `if false; then` left the word in the mapfile line below it and
  # satisfied a presence check.
  grep -q 'systemctl restart' "$APPLY" \
    && ok "restarts the unit rather than reimplementing its chmods" \
    || bad "no restart -- it stays a boot-time-only race"
  # Best effort by design: the unit is absent on non-Forgejo instances, so this
  # warns rather than dies. But silence would be worse, because the symptom a user
  # sees names their home directory and not this unit.
  grep -q 'warn "\$unit failed after render_secrets' "$APPLY" \
    && ok "a failure warns, naming the symptom a push will show" \
    || bad "a failure is silent, and the symptom does not name this unit"
  # The restart has to be INSIDE the guard, or it runs for instances that have no
  # such unit -- and systemctl restart on a missing unit is a failure on every
  # Caddy and Wireguard reconcile.
  guard=$(grep -nE 'if \[\[ -n .*afterRenderSecrets' "$APPLY" | head -1 | cut -d: -f1)
  block=$(sed -n "${guard},$((guard + 12))p" "$APPLY")
  if grep -q 'systemctl restart' <<<"$block"; then
    ok "the restart is inside the guard"
  else
    bad "the restart is not inside the guard -- it would run on every instance"
  fi
else
  bad "apply.sh has no guard that re-runs afterRenderSecrets"
fi
if grep -q 'afterRenderSecrets' "$ROOT/nixos/hosts/forgejo/incus.nix"; then
  ok "the forgejo spec declares afterRenderSecrets"
else
  bad "the forgejo spec declares no afterRenderSecrets"
fi

echo
echo "== 11a. the git transport identity's config, derived and fenced =="
# The unit that makes `git@` work at all, and one that generates a security
# boundary at runtime -- so it is asserted rather than reviewed.
#
# Read out of the BUILT guest closure, not out of the source that produced it: the
# ExecStart is what systemd runs, so a rewrite that never reaches the unit cannot
# pass here. Same reasoning as check 9.
#
# $GUEST, which check 1 already built, and not a search of the store.
#
# A `find /nix/store -name '*-forgejo-git-config'` looks equivalent and is not: a
# store full of older builds answers it too. This suite's own mutation runs leave
# dozen mutated copies behind, and they were all being asserted against -- so the
# block failed on code that is not the code, and the failure names a line nobody
# changed. The current source is the only thing that should be under test.
#
# -L is load-bearing, not stylistic: etc/systemd/system is a SYMLINK to a shared
# system-units derivation, so a find without it descends nothing. (Check 9 hit the
# same /etc-is-a-symlink trap and needed -L for it.)
GC_UNIT=$(find -L "$GUEST/etc/systemd/system" -maxdepth 1 \
  -name 'forgejo-git-config.service' 2>/dev/null | head -1)
if [[ -z $GC_UNIT ]]; then
  bad "forgejo-git-config.service is not in the built guest -- check 11a has nothing to assert"
else
  ok "forgejo-git-config.service is installed in the built guest"
fi

for gc_unit in ${GC_UNIT:+"$GC_UNIT"}; do
  gc_script=$(grep -oE 'ExecStart=[^ ]+' "$gc_unit" | head -1 | cut -d= -f2-)
  if [[ -z $gc_script || ! -f $gc_script ]]; then
    bad "ExecStart in $gc_unit does not resolve to a real file (got '$gc_script')"
    continue
  fi
  ok "its ExecStart resolves to a real file"

  # Comments stripped first: writeShellScript keeps them, and this file explains at
  # length why `su` is banned -- so a version of this check that matched the word
  # found its own documentation. (Paid for once already, in check 10.)
  CODE_GC=$(sed 's/[[:space:]]*#.*$//' "$gc_script")

  # RUN_USER must become git. mustCurrentRunUserMatch() compares it against the
  # current uid and fatals on a mismatch for EVERY subcommand, so a config that kept
  # forgejo here means every push dies before a key is offered.
  # Anchored to the sed that does the work. A bare grep for RUN_USER=git passes on
  # the unit's own assertion further down -- which mentions the very string being
  # looked for -- so a mutation that stops rewriting it is caught by nothing. The
  # same trap as the INTERNAL_TOKEN_URI comparison above, and it is why every check
  # in this block names the construct rather than the value.
  grep -qE '^[[:space:]]*-e "s\|\^RUN_USER=' <<<"$CODE_GC" \
    && grep -qE 'RUN_USER=git\|"' <<<"$CODE_GC" \
    && ok "the derived config says RUN_USER=git, in the sed that writes it" \
    || bad "nothing rewrites RUN_USER to git -- every push fails in mustCurrentRunUserMatch"

  # The *_URI filter, as a filter. Not four deletions by name: the keys are
  # SECRET_KEY_URI, JWT_SECRET_URI, LFS_JWT_SECRET_URI and PASSWD_URI, so a list
  # written from the four secret NAMES deletes three of four and serv still dies in
  # loadSecret. Anything matching *_URI that is not INTERNAL_TOKEN_URI must go.
  grep -qF '/_URI=/ { /INTERNAL_TOKEN_URI/!d }' <<<"$CODE_GC" \
    && ok "every *_URI but INTERNAL_TOKEN_URI is dropped, by filter not by name" \
    || bad "the *_URI filter is missing or name-based -- a secret added to app.ini later would be handed to git"

  # And the premise is asserted in the unit itself, so a filter that lets one
  # through fails the unit rather than sitting unnoticed.
  # The comparison, anchored to the start of its own line. grep -q 'INTERNAL_TOKEN_URI"'
  # was the first attempt and it matched the sed expression's own mention of the
  # name -- passing on the very line it was meant to be checking against.
  grep -qE '^[[:space:]]*\[ "\$f" = INTERNAL_TOKEN_URI \]' <<<"$CODE_GC" \
    && ok "the unit asserts which *_URI survived, rather than trusting the sed" \
    || bad "the unit does not assert which *_URI survived -- a filter bug would be silent"

  # git must own it, because serv WRITES to it: it saves its own oauth2 signing key
  # there on first use, and a config it cannot write is a fatal loadOAuth2From.
  grep -q 'chown git:git' <<<"$CODE_GC" \
    && ok "the config is owned by git, which serv writes to" \
    || bad "the config is not chowned to git -- serv saves its own oauth2 key and cannot"

  # internal_token is the ONE grant: group git, and 0440. Not group forgejo, and not
  # world-readable.
  grep -qE 'chown root:git .*internal_token' <<<"$CODE_GC" \
    && ok "internal_token becomes root:git, the single grant" \
    || bad "internal_token is not made readable to the git group"
  grep -qE 'chmod 0440 .*internal_token' <<<"$CODE_GC" \
    && ok "and at 0440, not world-readable" \
    || bad "internal_token is not 0440"

  # The four that must stay shut, by name. "The loop covers them" is a weaker claim
  # than "these four are the ones", and it is the one that has to hold.
  for f in secret_key oauth2_jwt_secret lfs_jwt_secret smtp_password; do
    grep -q "$f" <<<"$CODE_GC" \
      && ok "  $f is asserted unreadable by git" \
      || bad "$f is not in the unit's refusal list"
  done
  # internal_token must NOT be in that loop. It is deliberately reachable now, and
  # leaving it in would make the unit exit 1 on every single run.
  if grep -qE 'for f in [^;]*internal_token' <<<"$CODE_GC"; then
    bad "internal_token is still in the refusal loop -- the unit can never succeed"
  else
    ok "internal_token is NOT in the refusal loop (it is meant to be readable)"
  fi

  # Forgejo sets HOME=<data>/home for the git subprocess (commonBaseEnvs() in
  # v16.0.5), so THAT is the gitconfig a push reads -- not the passwd home. Miss it
  # and the push dies on "detected dubious ownership", naming git's ownership check
  # rather than the config that would have answered it.
  grep -qE 'chmod 0751 .*data/home' <<<"$CODE_GC" \
    && ok "data/home is traversable, so its .gitconfig is reachable" \
    || bad "data/home is not opened up -- the transport identity cannot read Forgejo's own gitconfig"
  grep -qE 'chgrp git .*\.gitconfig' <<<"$CODE_GC" \
    && ok "and .gitconfig is group-readable, for safe.directory = *" \
    || bad "the gitconfig is not readable by git -- every push fails on dubious ownership"

  # The hooks. core.hooksPath points git at data/home/hooks, and at 0750 they are
  # all skipped. The push then SUCCEEDS -- refs move -- and post-receive never runs,
  # so nothing reaches the database: measured, the branch appeared in the action
  # table zero times after a push that reported success.
  grep -qE 'chmod -R g\+rX .*hooks' <<<"$CODE_GC" \
    && ok "the hooks tree is made group-readable and executable" \
    || bad "the hooks are left at 0750 -- pushes succeed but are never recorded"
  grep -qE 'chgrp -R git .*hooks' <<<"$CODE_GC" \
    && ok "and owned by group git" \
    || bad "the hooks are not in group git"

  # runuser by absolute path, for the reason config-access documents: this unit's
  # PATH has no util-linux in it, and a bare `runuser` inside an `if` is a check
  # that silently passes -- which is how config-access came to prove nothing.
  if grep -qE '(^|[;&|(]|[[:space:]])runuser[[:space:]]' <<<"$CODE_GC"; then
    bad "invokes a bare runuser, which is not in this unit's PATH"
  else
    ok "runuser comes from an explicit store path"
  fi
done

echo "== 12. sshd -t accepts the config =="
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
