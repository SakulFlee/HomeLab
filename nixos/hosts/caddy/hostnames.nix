# The hostnames Caddy is fronting.
#
# Plain data in its own file because it is needed in more than one place and
# because a list of twenty-one names buried inside a Caddyfile is exactly the
# thing that goes stale unnoticed. Adding a name here is what makes Caddy serve
# it; forgetting means a 404 on a name that used to work, so the list is
# deliberately explicit rather than a wildcard.
#
# Verified against the running Traefik on 2026-10-01, by requesting each name
# straight at the bridge address and treating a non-404 as routed:
#
#   curl --resolve <name>:443:10.0.0.1 https://<name>/
#
# That is the ground truth for what is live, and it found two names that are
# not in apps/ at all (grafana and nas are configured outside this repository,
# or in a manifest this grep did not reach) and one that is (fluxer).
[
  "sakul-flee.de"
  "www.sakul-flee.de"
  "grafana.sakul-flee.de"
  "hermes.sakul-flee.de"
  "hermes-dashboard.sakul-flee.de"
  "nas.sakul-flee.de"
  "ollama.sakul-flee.de"
  "open-webui.sakul-flee.de"
  "pvc-explorer.sakul-flee.de"
  "vpn.sakul-flee.de"
]

# Not in the list, and why:
#
# - jellyfin, sonarr, radarr, prowlarr and qui are each their own site block in
#   ../default.nix, proxying to their Incus instance. They left this list when
#   they left Traefik. Putting a name here would import still-traefik and hand
#   it straight back to k3s -- so a name must be in exactly one of the two
#   places, never both.
#
#   qbittorrent.sakul-flee.de is ALSO gone from this list but is NOT in a site
#   block either: that instance is not migrated yet, so the name currently
#   serves nothing from Caddy. It comes back with the qBittorrent cutover.
#
# - Nothing else routed by Traefik on homelab in that snapshot.
