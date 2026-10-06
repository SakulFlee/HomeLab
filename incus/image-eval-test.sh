#!/usr/bin/env bash
# Every instance image the flake claims to build actually evaluates, and the
# runner is registered as the kind of instance it has to be.
# Run it: NIX_SUDO=1 ./incus/image-eval-test.sh
#
# WHY THIS EXISTS, and why it is only about evaluation.
#
# NixOS does not check that an option exists when a module is read. A typo like
# `systemd.services.foo.requiresMountsFor` is a perfectly good attribute
# assignment; it only fails when `system.build.toplevel` is forced, which is to
# say when somebody builds the image. So this class of bug is invisible to
# review and to every other suite here -- apply-*.sh test functions extracted
# out of apply.sh and never evaluate the flake at all.
#
# Two real examples, found by this check and nothing else, both in
# nixos/hosts/forgejo-runner/default.nix:
#
#   systemd.services.forgejo-runner-config.requiresMountsFor
#     NixOS has no such option. `RequiresMountsFor=` is a systemd DIRECTIVE,
#     reached as `unitConfig.RequiresMountsFor` -- which is how nixpkgs itself
#     writes it, in swap.nix, alsa.nix and security/wrappers.
#
#   services.docker.enable
#     Also not a NixOS option, and the "obvious" correction of the line above
#     it is wrong too. `virtualisation.docker.enable` IS the Docker daemon: the
#     name reads the other way round, and its own description says "This option
#     enables docker, a daemon that manages linux containers." There is no
#     `services.docker`, and the option set has no `build` submodule, so nothing
#     there is about producing an image OF the system. The daemon unit
#     Requires=docker.service, so either spelling being wrong is fatal at boot
#     rather than at review.
#
# This evaluates; it does not build. Forcing `system.build.toplevel` is what
# surfaces a bad option name and evaluation alone does not do that -- hence the
# disk image, `image-<name>`, rather than the cheaper `system.build.toplevel`.
# The wireguard and forgejo images are the control: if all three come back
# empty the fault is this suite or the flake lock, not the runner.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FLAKE=${FLAKE:-$ROOT/nixos}
[[ -f $FLAKE/flake.nix ]] || { echo "FATAL: no flake.nix at $FLAKE"; exit 99; }

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

nixq() {
  if [[ -n ${NIX_SUDO:-} ]]; then
    sudo -n env HOME=/root PATH=/run/current-system/sw/bin:$PATH \
      nix --extra-experimental-features 'nix-command flakes' "$@"
  else
    nix --extra-experimental-features 'nix-command flakes' "$@"
  fi
}

# nixq's stderr, kept because a bad option name is reported there and nowhere
# else. Written to a FILE rather than a variable on purpose: the call sites are
# `p=$(evalq ...)`, which runs the function in a subshell, so an assignment to
# a variable inside it is discarded before the caller can read it. The first
# version of this suite therefore reported "<nothing on stderr>" while nix was
# printing the exact error that explained the failure -- a check that states
# something false about what it could not see.
ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT
evalq() { nixq eval "$@" 2>"$ERRFILE"; }
err_tail() { tail -4 "$ERRFILE" | tr '\n' ' '; }

# =============================================================================
echo "== 1. every declared image evaluates to a store path =="
for pair in "image-forgejo:container" "image-wireguard:vm" "image-forgejo-runner:vm"; do
  attr=${pair%%:*}
  kind=${pair##*:}
  printf '  %-22s ' "$attr"
  p=$(evalq --raw "$FLAKE#$attr" | tail -1)
  if [[ -z $p ]]; then
    printf 'FAIL -- nix eval produced no out path\n'
    printf '       nix said: %s\n' "$(err_tail)"
    fails=$((fails + 1))
  elif [[ $p == /nix/store/* ]]; then
    printf 'ok   %-4s %s\n' "$kind" "$(basename "$p")"
  else
    printf 'FAIL -- not a store path: %s\n' "$p"
    fails=$((fails + 1))
  fi
done

# Nix will evaluate a dirty-tree flake without help but cannot always write
# the store, and "Permission denied: /nix/store/tmp-..." reads like a broken
# flake rather than a missing privilege. Say so once, in the terms of the
# flag that fixes it.
if [[ $fails -gt 0 && -z ${NIX_SUDO:-} ]] && grep -q 'Permission denied' "$ERRFILE"; then
  echo
  echo "  hint: NIX_SUDO=1 if nix needs root to write the store"
fi

# =============================================================================
echo
echo "== 2. the runner is registered, and registered as a VM =="
# Not cosmetic. The Docker executor runs a container runtime inside the guest,
# which an LXC could only do privileged -- handing it the host kernel, the
# thing the repo's "LXC unless privileged, then VM" rule refuses. A silent
# change to `container` here would produce an instance that boots and cannot
# run a job.
INSTANCES=$(evalq --json "$FLAKE#incusInstances" | tail -1)
if [[ -z $INSTANCES ]]; then
  printf '  FAIL could not read incusInstances\n'
  printf '       nix said: %s\n' "$(err_tail)"
  fails=$((fails + 1))
else
  if printf '%s' "$INSTANCES" | jq -e '.["forgejo-runner"]' >/dev/null 2>&1; then
    check "forgejo-runner is in the instance registry" "yes" "yes"
  else
    check "forgejo-runner is in the instance registry" "yes" "no"
  fi
  TYPE=$(printf '%s' "$INSTANCES" | jq -r '.["forgejo-runner"].type // "<absent>"' 2>/dev/null)
  check "and its type is vm" "vm" "$TYPE"
  WIRE=$(printf '%s' "$INSTANCES" | jq -r '.wireguard.type // "<absent>"' 2>/dev/null)
  check "wireguard agrees (the control)" "vm" "$WIRE"
fi

echo
if [[ $fails -eq 0 ]]; then
  echo "all checks passed"
else
  echo "$fails check(s) FAILED"
fi
exit $((fails > 0))