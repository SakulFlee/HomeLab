#!/usr/bin/env bash
# Run Renovate once against Forgejo. The compose profile keeps it out of the
# normal `up -d` path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_root
require_cmd docker
stack_exists renovate || die "renovate stack is missing"

"${SCRIPT_DIR}/render-secrets.sh"
compose renovate --profile renovate run --rm renovate
# No success notification: this runs hourly, and a failed run is already
# reported by the unit's OnFailure handler.
