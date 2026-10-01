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
  "forgejo.sakul-flee.de"
  "fluxer.sakul-flee.de"
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
#   incus.sakul-flee.de     added when the Incus UI block lands, with the
#                           VPN/LAN gating and its own client certificate.
#   matrix.sakul-flee.de    Matrix needs the federation listener on :8448 and a
#   matrix-well-known...    /.well-known on :443. Neither is routed through
#                           Traefik's web entrypoint today, so there was
#                           nothing to catch.
#   minecraft/hytale/       raw TCP/UDP (25565, 5520/udp, 7881, 7882). An L7
#   livekit-*               proxy cannot carry these; they need an
#                           `incus network forward` per port when they move,
#                           which is L4 and does not involve Caddy at all.
#   wg.sakul-flee.de        WireGuard's own entrypoint, not HTTP.
