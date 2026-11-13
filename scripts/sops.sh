#!/usr/bin/env bash
# Run sops with the host's age identity path, regardless of whether the caller
# is root or a normal user. This avoids the common "works in render-secrets.sh
# but not from a manual sudo sops" confusion.
set -euo pipefail

if [[ -r /etc/sops/age/keys.txt ]]; then
  export SOPS_AGE_KEY_FILE=/etc/sops/age/keys.txt
fi

exec sops "$@"
