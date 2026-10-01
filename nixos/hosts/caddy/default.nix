{ lib, pkgs, ... }:

let
  # The names Caddy is fronting, kept in their own file so the list can be
  # reviewed and reused without being buried in a Caddyfile.
  hostnames = import ./hostnames.nix;

  # Precomputed rather than generated inside the Caddyfile below: a Nix
  # indented string cannot contain another `''`-literal, so a concatMapStrings
  # with a nested one does not parse. Tabs, because that is what `caddy fmt`
  # emits and it rewrites spaces regardless of what we hand it.
  hostBlocks = lib.concatMapStrings
    (h: ''${h} {
	import still-traefik
}
'')
    hostnames;

  # nixpkgs' caddy has no DNS providers compiled in, so `acme_dns cloudflare`
  # fails with
  #   module not registered: dns.providers.cloudflare
  # which `caddy validate` reports as a config error even though the rest of the
  # file adapts fine. withPlugins rebuilds through xcaddy with the one provider
  # needed, rather than libdns and every provider it drags in.
  #
  # The hash is a fixed-output hash over the Go module graph, so it has to be
  # known before the build. Discovered by building once with `hash =
  # lib.fakeHash`; do that again after touching `plugins`.
  caddyPkg = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
    hash = "sha256-hEHgAG0F0ozHRAPuxEqLyTATBrE+pajeXDiSNwniorg=";
  };
in
{
  # NixOS system container for the Incus instance "caddy".
  #
  # Front door for everything in the homelab. Right now it terminates TLS for
  # all twenty hostnames and hands every one of them straight back to Traefik;
  # as each app moves to Incus its block stops importing the `still-traefik`
  # snippet and proxies to its own instance instead. See incus.nix for the
  # container-level definition (limits, volumes, devices).

  networking.hostName = "caddy";

  # The host firewall is what gates this. Inside the container we only need to
  # bind the ports; no second layer of filtering, which would break the
  # incus network forward DNAT that points here.
  networking.firewall.enable = false;

  # Address comes from Incus' dnsmasq on incusbr0. Hostname resolution is
  # forwarded to the LAN resolver (the host's own /etc/resolv.conf points at
  # the router); Incus' embedded DNS is only authoritative inside the bridge.
  networking.nameservers = [ "192.168.178.1" ];

  # SSH is not exposed (Incus reaches the instance via exec, and there is no
  # network forward for 22). Keeping it disabled removes the key-management
  # problem entirely.
  services.openssh.enable = false;

  # No sops, no age, and no decryption capability of any kind. The Cloudflare
  # token reaches this instance as a rendered EnvironmentFile that the host
  # writes in -- see the renderedSecrets stanza in incus.nix. An earlier version
  # imported sops-nix here and bind-mounted the host's SSH identity key so the
  # container could decrypt for itself; that granted a root process in here the
  # ability to read every secret in the host's secrets.yaml, and the only thing
  # limiting that was remembering not to do it.
  environment.systemPackages = with pkgs; [
    curl
    # Deliberately NOT dig: bind-tools drags in perl + boost + icu4c, roughly
    # 130MB of the image for a debugging convenience. Use `incus exec <name> --
    # curl` against an upstream, or resolve from the host instead.
    jq
  ];

  # ---------------------------------------------------------------------
  # Caddy
  # ---------------------------------------------------------------------

  services.caddy = {
    enable = true;
    email = "dev@sakul-flee.de";

    # The build that has the Cloudflare DNS provider compiled in. Without this
    # the acme_dns global option below is an unknown module.
    package = caddyPkg;

    # Written by the host, into the caddy-secrets volume, by apply.sh. Not
    # optional: if it is missing, systemd should say so plainly rather than
    # letting Caddy start and then fail on an empty API token.
    environmentFile = "/var/lib/incus-secrets/caddy-env";

    # Written by hand below, then passed through `caddy fmt` so the file Caddy
    # loads is canonical. Nix indented strings are space-indented and Caddy
    # insists on tabs, so without this it logs
    #   Caddyfile input is not formatted; run 'caddy fmt --overwrite'
    # on every start, forever. Formatting at build time makes the warning
    # impossible rather than ignored.
    configFile = pkgs.runCommand "Caddyfile" { nativeBuildInputs = [ caddyPkg ]; } ''
      cp ${pkgs.writeText "Caddyfile.in" ''
        {
          email dev@sakul-flee.de

          # DNS-01, because these names are only ever resolved by Cloudflare --
          # the A record for sakul-flee.de points at the public IP and nothing
          # inbound here can be reached to answer an HTTP-01 challenge.
          #
          # Explicit hostnames below rather than a wildcard. A wildcard would be
          # one certificate instead of twenty-one, which does matter against
          # Let's Encrypt's 50-per-registered-domain-per-week ceiling, but it
          # also covers names nothing is meant to serve. Twenty-one is well
          # inside the limit and Caddy staggers renewals anyway.
          acme_dns cloudflare {env.CF_API_TOKEN}
        }

        # Every hostname below is currently served by Traefik inside k3s, and
        # every one of them keeps being served by Traefik until the app itself
        # is migrated. This is a pure cutover of the front door: TLS terminates
        # at Caddy and the request is handed back to Traefik over the bridge.
        #
        # 10.0.0.1 is incusbr0's own address, and Traefik answers there because
        # it runs hostNetwork: true and binds every host address. That is what
        # makes this loop-free: the incus network forward DNATs
        # 192.168.178.200:80/443 to Caddy, and that rule matches on the listen
        # address, so traffic aimed at 10.0.0.1 is never rewritten. Verified
        # end to end from inside this container before the forward existed:
        #
        #   curl --resolve forgejo.sakul-flee.de:443:10.0.0.1 \
        #        https://forgejo.sakul-flee.de/    ->  http 200, verify 0
        #
        # Two things here are load-bearing and neither is guessable:
        #
        #   header_up Host {http.request.host}
        #     Since Caddy v2.11.0, proxying to an https:// upstream sets the
        #     Host header to the upstream's hostport automatically. So Traefik
        #     received `Host: 10.0.0.1`, matched no IngressRoute, and answered
        #     404 for all twenty names while TLS verified perfectly and Caddy
        #     reported success. {http.request.host} rather than the documented
        #     {hostport} opt-out, because hostport keeps an explicit :443 if a
        #     client sends one and Traefik's host matcher would not match it.
        #
        #   tls_server_name {http.request.host}
        #     Traefik turns out to route on Host and not on SNI -- a request
        #     with no SNI at all still gets 200 -- so this is belt and braces
        #     rather than the fix. It is here because if Traefik is ever
        #     reconfigured to select routers by SNI, the dialled address being
        #     an IP would silently break it.
        (still-traefik) {
          reverse_proxy https://10.0.0.1 {
            header_up Host {http.request.host}
            transport http {
              tls
              tls_server_name {http.request.host}
            }
          }
        }

        ${hostBlocks}
      ''} $out
      # cp from the store preserves mode 0444, which `caddy fmt --overwrite`
      # cannot write to. The build sandbox would fail with "permission denied".
      chmod u+w $out
      ${caddyPkg}/bin/caddy fmt --overwrite $out
    '';

    # The NixOS firewall is disabled above, so this must stay off or it tries to
    # manage rules that do not exist in this container.
    openFirewall = false;

    # Reload rather than restart on config change: Caddy reloads its own config
    # gracefully, a restart drops in-flight connections.
    enableReload = true;
  };

  # ACME certificates land in /var/lib/caddy, which is the backup-pool volume
  # declared in hosts/caddy/incus.nix -- so a recreate does not re-trigger
  # issuance and does not risk Let's Encrypt rate limits.
  systemd.tmpfiles.rules = [ "d /var/lib/caddy 0755 caddy caddy" ];
}
