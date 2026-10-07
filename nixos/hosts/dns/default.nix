# NixOS system container for the Incus instance "dns".
#
# The split-horizon resolver for the homelab: VPN-only names answer with the
# host's LAN address so VPN (and LAN) clients route them into the tunnel with
# a 100.64.0.x source; everything else forwards upstream. This used to be a
# hostNetwork CoreDNS Deployment in k3s (apps/wireguard/split-dns-*); moving
# it here retires that Deployment and leaves k3s out of the DNS path entirely.
#
# Stateless: the zone is this file, not a database, so there is no volume, no
# snapshot policy and nothing for restic to back up. A recreate loses nothing.
{ lib, pkgs, ... }:
let
  # Every VPN-only hostname, in one list so the three match regexes below
  # cannot drift from each other. A name missing here falls through to the
  # public wildcard, reaches Caddy/Traefik from a Cloudflare edge IP instead
  # of 100.64.0.x, and is rejected with 403 even for a connected client.
  #
  # Keep in lockstep with the Traefik `vpn-only` ingresses until those apps
  # migrate to Incus, and with the Caddy VPN-gated vhosts (incus, ttyd) after.
  vpnOnlyNames = [
    "incus"
    "hermes-dashboard"
    "hermes"
    "ollama"
    "open-webui"
    "jellyfin"
    "sonarr"
    "radarr"
    "prowlarr"
    "qbittorrent"
    "qui"
    "grafana"
    "paperless"
    "syncthing"
    "nas"
    "vpn"
    "pvc-explorer"
    "ttyd"
  ];

  namePattern = lib.concatStringsSep "|" vpnOnlyNames;
in
{
  networking.hostName = "dns";

  # Same posture as the caddy container: no second layer of filtering inside
  # the guest. The proxy devices in incus.nix deliver host .200:53 here; the
  # answers themselves are public-safe (private names to .200, everything else
  # forwarded upstream), so there is no gate to enforce at this layer.
  networking.firewall.enable = false;

  # The router, NOT the host's own .200. That address is served by *this*
  # container through the proxy devices below -- pointing resolv.conf at it
  # would make the guest resolve through itself.
  networking.nameservers = [ "192.168.178.1" ];

  # Not exposed (Incus reaches the instance via exec, and nothing forwards
  # 22). Same reasoning as the caddy container.
  services.openssh.enable = false;

  environment.systemPackages = with pkgs; [
    # dig is bind.host, not bind-tools: the full tools derivation drags in
    # perl + boost + icu4c, roughly 130MB of image for a debugging
    # convenience. bind.host is the small client-only split.
    bind.host
  ];

  # ---------------------------------------------------------------------
  # CoreDNS
  # ---------------------------------------------------------------------
  # Verbatim Corefile, translated 1:1 from the retired k3s ConfigMap
  # (apps/wireguard/coredns-configmap.yaml, now deleted).
  #
  # No `bind` line, deliberately. The k3s Corefile bound 192.168.178.200
  # because the pod shared the host's network namespace. This container has
  # only eth0 (10.0.0.53) and lo, so listening everywhere inside the guest
  # reaches exactly the address the proxy devices dial -- and there is no
  # second literal to drift from incus.nix when the address changes.
  services.coredns = {
    enable = true;
    config = ''
      .:53 {
          # Split horizon. VPN-only service names resolve to the host so VPN
          # clients route them into the tunnel; AAAA and HTTPS are suppressed
          # for the same names so clients cannot prefer a Cloudflare edge
          # address (which would bypass the tunnel and be rejected by the
          # VPN-only gates).
          template IN A {
              match "^(${namePattern})\.sakul-flee\.de\.$"
              answer "{{ .Name }} 60 IN A 192.168.178.200"
              fallthrough
          }
          template IN AAAA {
              match "^(${namePattern})\.sakul-flee\.de\.$"
              rcode NOERROR
              fallthrough
          }
          template IN HTTPS {
              match "^(${namePattern})\.sakul-flee\.de\.$"
              rcode NOERROR
              fallthrough
          }
          # Everything else (public names, wg endpoint, internet) goes
          # upstream unchanged.
          forward . 9.9.9.9 149.112.112.112
          cache
          errors
          reload
      }
    '';
  };
}
