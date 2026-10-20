#!/usr/bin/env bash
#
# One-time adoption of the live Incus setup into OpenTofu state.
#
# Run as root on the homelab host, from anywhere. This does NOT build images or
# change anything in Incus; it only records what already exists. The first
# `tofu apply` afterwards creates the new images and rolls the instances onto
# them.
#
# Images and the server cannot be imported (the provider has no ImportState for
# either). Images are absent from the import list on purpose: `tofu apply`
# creates them. `incus_server.this` is likewise adopted by its Create, which
# merges our keys into the live server config.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
flake="$repo_root/nixos"
infra="$repo_root/incus/infra"

die() { echo "error: $*" >&2; exit 1; }

command -v tofu >/dev/null || die "tofu is not installed"
command -v incus >/dev/null || die "incus is not installed"
command -v jq >/dev/null || die "jq is not installed"
[[ $EUID -eq 0 ]] || die "run as root (tofu and the incus socket need it)"

[[ -f $infra/generated.tf.json ]] || die "run incus/gen-tf.sh first"

# Resource labels are normalised the same way as in nixos/incus-tf.nix.
label() { local s=${1//-/_}; printf '%s' "${s//./_}"; }

if ! tofu -chdir="$infra" state list >/dev/null 2>&1; then
  echo "initialising OpenTofu"
  tofu -chdir="$infra" init -input=false
fi

in_state() { tofu -chdir="$infra" state show "$1" >/dev/null 2>&1; }

adopt() {
  local addr=$1 id=$2
  if in_state "$addr"; then
    echo "  already imported: $addr"
  else
    echo "  import $addr  <-  $id"
    tofu -chdir="$infra" import -input=false "$addr" "$id"
  fi
}

instances_json=$(nix eval --json "$flake#incusInstances")
instance_projects_json=$(nix eval --json "$flake#incusInstanceProjects")
projects_json=$(nix eval --json "$flake#incusProjects")

echo "projects"
while read -r project; do
  adopt "incus_project.$(label "$project")" "$project"
done < <(jq -r 'keys[]' <<<"$projects_json")

echo "pool, network and default profile"
adopt incus_storage_pool.persistent persistent
adopt incus_network.incusbr0 incusbr0
# Creating the built-in profile through the provider adopts and updates it.
adopt incus_profile.default default

echo "storage volumes"
while read -r instance; do
  project=$(jq -r --arg i "$instance" '.[$i] // ""' <<<"$instance_projects_json")
  while read -r volume; do
    # The provider treats the first component before a slash as the project.
    # The leading slash is an explicit empty project, needed because the pool
    # and name are both required fields.
    if [[ -n $project ]]; then
      volume_id="$project/persistent/$volume"
    else
      volume_id="/persistent/$volume"
    fi
    adopt "incus_storage_volume.$(label "$volume")" "$volume_id"
  done < <(jq -r --arg i "$instance" '.[$i].volumes[]?.name' <<<"$instances_json")
done < <(jq -r 'keys[]' <<<"$instances_json")

echo "network forwards"
# Same provider parsing quirk as volumes: the leading slash is an explicit
# empty project, otherwise incusbr0 would be read as the project name.
while IFS=$'\t' read -r resource id; do
  adopt "incus_network_forward.$resource" "$id"
done < <(jq -r '
  .resource.incus_network_forward // {}
  | to_entries[]
  | "\(.key)\t/\(.value.network)/\(.value.listen_address)"
' "$infra/generated.tf.json")

echo "instances"
while read -r instance; do
  project=$(jq -r --arg i "$instance" '.[$i] // ""' <<<"$instance_projects_json")
  live_project=${project:-default}
  fingerprint=$(incus query "/1.0/instances/${instance}?project=${live_project}" \
    | jq -r '.config["volatile.base_image"] // empty')
  [[ -n $fingerprint ]] || die "cannot read volatile.base_image for $instance"
  id="${instance},image=${fingerprint}"
  [[ -n $project ]] && id="${project}/${id}"
  adopt "incus_instance.$(label "$instance")" "$id"
done < <(jq -r 'keys[]' <<<"$instances_json")

cat <<EOF

Imported. Next:

  tofu -chdir=$infra plan -out=roll.tfplan

The plan creates every incus_image and replaces every instance onto its new
image (volumes are untouched). Review it, then:

  tofu -chdir=$infra apply roll.tfplan
EOF
