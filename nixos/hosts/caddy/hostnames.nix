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
  "fluxer.sakul-flee.de"
  "fluxer-next.sakul-flee.de"
  "grafana.sakul-flee.de"
  "hermes.sakul-flee.de"
  "hermes-dashboard.sakul-flee.de"
  "jellyfin.sakul-flee.de"
  "nas.sakul-flee.de"
  "ollama.sakul-flee.de"
  "open-webui.sakul-flee.de"
  "paperless.sakul-flee.de"
  "prowlarr.sakul-flee.de"
  "pvc-explorer.sakul-flee.de"
  "qbittorrent.sakul-flee.de"
  "qui.sakul-flee.de"
  "radarr.sakul-flee.de"
  "sonarr.sakul-flee.de"
  "syncthing.sakul-flee.de"
  "vpn.sakul-flee.de"
]

# Not in the list, and why:
#
# - Nothing else routed by Traefik on homelab in that snapshot.
