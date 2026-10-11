# NixOS system for the Incus instance "cloudflare-ddns".
#
# Replaces the k3s CronJob in apps/cloudflare-ddns/ (a hand-written ddns.py run
# on a schedule) with the purpose-built client nixpkgs already ships:
# favonia/cloudflare-ddns, a single Go binary, wrapped by the
# services.cloudflare-ddns module. Same job -- push the router's public address
# into Cloudflare whenever it changes -- but as a long-running daemon with a
# cache instead of a Python script re-parsing a configmap.
#
# It manages two names, both of which have to follow the WAN address:
#
#   sakul-flee.de      the apex A record
#   wg.sakul-flee.de  the WireGuard endpoint, dialled as wg.sakul-flee.de:51820
#
# The domains are declared here rather than kept in a secret. They are public
# DNS names -- anyone can look them up -- so treating them as a secret bought
# nothing and cost a rendered file. The old k3s app read them from a secret;
# this is the same list, in the open.
{ config, lib, pkgs, ... }:
{
  networking.hostName = "cloudflare-ddns";

  # Outbound HTTPS only: 1.1.1.1 for the IP check and api.cloudflare.com for
  # the update. Nothing listens, nothing is forwarded, so there is no attack
  # surface to gate -- the host firewall is the boundary that matters and this
  # instance is behind it on incusbr0.
  networking.firewall.enable = false;

  # The router, like every other instance. This has to be able to resolve
  # api.cloudflare.com at all, so it is not optional.
  networking.nameservers = [ "192.168.178.1" ];

  # Nothing here is worth logging into; `incus exec` goes through the API and
  # does not need a daemon listening for it.
  services.openssh.enable = false;

  # ---------------------------------------------------------------------------
  # Why this works from inside a container
  # ---------------------------------------------------------------------------
  #
  # The obvious worry about DynDNS in an LXC is that the container has a
  # private address and no idea what the public one is. It does not need to:
  # provider.ipv4 defaults to `cloudflare.trace`, which fetches
  # https://1.1.1.1/cdn-cgi/trace and takes the address *Cloudflare sees*.
  # Egress from incusbr0 is NAT'd by the host, so that is the router's WAN
  # address -- exactly what the A record must hold, and exactly what the old
  # k3s pod got when it fetched icanhazip through the same NAT.
  #
  # So this never reads the container's own interfaces. `local` would be wrong
  # here (it would report 10.0.0.113), and nothing below uses it.
  #
  # Running it on the host instead would change nothing about detection: the
  # host only holds 192.168.178.200 too, so its public address is equally
  # external. The container is the better home for the usual reasons.
  services.cloudflare-ddns = {
    enable = true;

    # Written by incus/apply.sh as `CLOUDFLARE_API_TOKEN=<value>` from the
    # host's own sops.secrets.cloudflare_api_token -- the same token caddy uses
    # for ACME DNS-01, so no new secret was minted for this. The module hands
    # the path straight to systemd as EnvironmentFile, which is opened as root
    # before the unit drops to its own user; the 0400 root:root apply.sh
    # renders by default is therefore correct, unlike caddy's PEMs.
    #
    # The zone is not configured here on purpose: this client discovers it from
    # the API, so cloudflare_zone_id is not needed. Nothing scopes it to one
    # zone either -- it manages whatever the token can reach.
    credentialsFile = "/var/lib/incus-secrets/cloudflare-ddns-env";

    domains = [
      "sakul-flee.de"
      "wg.sakul-flee.de"
    ];

    # IPv4 only. The homelab has no IPv6 to speak of: hosts/dns suppresses
    # AAAA records, the router forwards terminate at 192.168.178.200, and
    # incusbr0 carries no IPv6 at all. Left at its default this client would
    # try to detect a v6 address, find none, and log an error every five
    # minutes -- noise that would look like a real fault.
    #
    # If native IPv6 is ever added, the fix is to give this instance IPv6
    # egress and set this back to "cloudflare.trace"; detection is still
    # external, so it does not have to move to the host to work.
    provider.ipv6 = "none";

    # The records the retired script wrote were TTL 120, and this keeps them at
    # 120 rather than dropping to 1 (automatic). A wrong TTL outlives the tool
    # that set it -- every resolver caches for two minutes until something else
    # changes it -- so the safer value is the one already in the zone.
    #
    # proxied is left at its default "false", and that is load-bearing rather
    # than incidental: wg.sakul-flee.de serves WireGuard on UDP 51820, and
    # Cloudflare only proxies HTTP(S) on a fixed port list. Orange-clouding it
    # would take the VPN down for everyone outside the LAN.
    ttl = 120;
  };

  # updateCron stays at its default "@every 5m", which is what the k3s
  # CronJob used (*/5 * * * *). This is a daemon rather than a scheduled job,
  # so it also retries internally instead of waiting for the next tick.
}