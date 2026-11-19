#!/usr/bin/env bash
# Install the Dendra-side restic mirror scripts into ~/.local/bin.
#
# The copies in this directory are canonical: edit them here, commit, then run
# this again. (They used to live only in ~/.local/bin, unversioned, and the
# repository path silently drifted between the three scripts.)
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${HOME}/.local/bin"

install -d -m 0755 "${dest}"
for f in homelab-restic-common.sh homelab-restic-pull.sh \
         homelab-restic-prune.sh homelab-restic-check.sh; do
  install -m 0755 "${src}/${f}" "${dest}/${f}"
  echo "installed ${dest}/${f}"
done

echo "systemd user timers load the installed copies; the unit files themselves"
echo "are in ~/.config/systemd/user/homelab-restic-* on this machine."
