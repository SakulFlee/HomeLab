#!/usr/bin/env bash
#
# Build every instance image artefact and regenerate the OpenTofu
# configuration from the flake. Run this on the homelab host before
# `tofu plan` / `tofu apply`.
#
# The artefact out-links under incus/infra/.artifacts/ are GC roots: the store
# paths are written into generated.tf.json, so they must not be collected
# between this run and the apply.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
flake="$repo_root/nixos"
infra="$repo_root/incus/infra"

mkdir -p "$infra/.artifacts"

mapfile -t names < <(
  nix eval --raw "$flake#incusTfArtifacts" \
    --apply 'x: builtins.concatStringsSep "\n" (builtins.attrNames x)'
)

for name in "${names[@]}"; do
  [[ -n $name ]] || continue
  echo "building image artefact: $name"
  nix build "$flake#incusTfArtifacts.$name" --out-link "$infra/.artifacts/$name"
done

echo "writing $infra/generated.tf.json"
nix eval --raw "$flake#incusTfJson" > "$infra/generated.tf.json.tmp"
mv "$infra/generated.tf.json.tmp" "$infra/generated.tf.json"
