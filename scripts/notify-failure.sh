#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

unit="${1:-unknown}"
if [[ -r /etc/homelab/notify.env ]]; then
  # shellcheck disable=SC1091
  source /etc/homelab/notify.env
fi
notify "HomeLab unit failed" "${unit} failed on $(hostname)" critical
