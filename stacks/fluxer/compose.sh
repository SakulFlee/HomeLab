#!/usr/bin/env bash
# Run Fluxer with the project's host config (ports, bind IPs), the upstream
# files, the proxy overlay and the homelab override. Compose `include` does not
# merge the proxy overlay environment reliably, so this uses explicit files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib.sh
source "${SCRIPT_DIR}/../../scripts/lib.sh"

compose fluxer "$@"
