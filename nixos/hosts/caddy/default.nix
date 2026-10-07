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
  # The hash is a fixed-output hash over the built binary, so it has to be
  # known before the build. Discovered by building once with `hash =
  # lib.fakeHash`; do that again after touching `plugins`.
  #
  # It also moves with the Go toolchain, which is worth stating because it is
  # not obvious from the expression: the inputs are unchanged (same caddy
  # 2.11.4, same plugin v0.2.4), but a different Go emits a different binary.
  # Moving from nixpkgs-unstable to nixos-26.05 took Go from 1.26.4 to 1.26.7
  # and produced:
  #
  #   hash mismatch in fixed-output derivation
  #     'caddy-src-with-plugins-ea5480ecce2b088b2b65ad3423502471-2.11.4':
  #      specified: sha256-hEHgAG0F0ozHRAPuxEqLyTATBrE+pajeXDiSNwniorg=
  #         got:    sha256-dQvk6ezY6TQ1J7PjhCXnThF/SqVgPwBO8/RXzHCY+js=
  #
  # So expect to rediscover this on every nixpkgs bump, not just when the
  # plugin list changes. It fails late and indirectly: the error names the
  # Caddy package, then etc, then Caddyfile, then the whole image, four levels
  # away from the line that is actually wrong.
  caddyPkg = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
    hash = "sha256-dQvk6ezY6TQ1J7PjhCXnThF/SqVgPwBO8/RXzHCY+js=";
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

        # -------------------------------------------------------------------
        # forgejo.sakul-flee.de -- CUTOVER: now served by the Incus instance
        # The first name to leave Traefik. This used to be one entry in
        # hostnames.nix and inherit the shared still-traefik snippet; it is now a
        # site block of its own pointing straight at 10.0.0.101:3000.
        #
        # Traefik in k3s is still running and still has this data. Nothing about k3s
        # has been removed -- only the route in front of it changed. Rolling back is
        # putting the name back in hostnames.nix and deleting this block.
        #
        # Plain http:// upstream, not https:// like still-traefik uses. The instance
        # speaks plain HTTP inside the container and its certificate was issued for a
        # name that never resolves there, so there is nothing to verify and nothing to
        # trust.
        #
        # header_up Host is required rather than cosmetic. Forgejo compares the Host
        # header against its configured DOMAIN, forgejo.sakul-flee.de, and answers 404
        # when they disagree -- so this must send the name the browser asked for, which
        # is exactly what {http.request.host} is. There is no address rewriting needed:
        # the upstream is a plain IP and Forgejo is not matching on it.
        #
        # The instance listens on 10.0.0.101:3000. Verified before this change, direct
        # and through Caddy:
        #
        #   curl http://10.0.0.101:3000/api/v1/version
        #     ->  {"version":"16.0.5"}          the nixpkgs build
        #   curl --resolve forgejo.sakul-flee.de:443:127.0.0.1 \
        #        https://forgejo.sakul-flee.de/api/v1/version
        #     ->  {"version":"16.0.5+gitea-1.22.0"}   k3s, for contrast
        forgejo.sakul-flee.de {
          reverse_proxy http://10.0.0.101:3000 {
            header_up Host {http.request.host}
          }
        }
        # -------------------------------------------------------------------


        # -------------------------------------------------------------------
        # The Incus UI
        # -------------------------------------------------------------------
        # The one hostname here that Caddy serves itself rather than handing to
        # Traefik, and the reason apply.sh renders a client certificate into
        # this instance and trusts it with Incus (see incusTrust in incus.nix).
        #
        # A separate site block, NOT another entry in hostnames.nix: those all
        # import still-traefik. There is no catch-all site block to collide
        # with either -- Caddy has no site block for a host it does not know, and
        # answers those itself with a 404.
        #
        # VPN only, and `remote_ip` rather than `client_ip`:
        #
        #   remote_ip    The address the connection actually came from. Since
        #                the incus network forward is a DNAT and does not
        #                rewrite the source, this is the real client address.
        #                Unforgeable.
        #   client_ip    Trusts X-Forwarded-For. Caddy is the edge here, so
        #                nothing legitimate sets it -- which means anyone can,
        #                and with no trusted_proxies configured the gate becomes
        #                a one-header bypass.
        #
        # The range is the WireGuard tunnel subnet, matching the
        # `vpn-only` Traefik middleware that already gates grafana, jellyfin,
        # paperless and the rest. Deliberately NOT lan-or-vpn: Caddy holds a
        # trusted client certificate, and Incus has no RBAC, so anything that
        # passes this gate is a full administrator of the host. The direct API
        # on :8443 stays reachable from the LAN for the `incus` CLI, which is
        # gated by your own certificate instead.
        incus.sakul-flee.de {
            tls {
                dns cloudflare {env.CF_API_TOKEN}
            }

            @notvpn not remote_ip 100.64.0.0/10
            # `respond` sorts before `reverse_proxy` in Caddy's directive order,
            # so this short-circuits without needing a handle block. A body
            # rather than a bare abort: an unexplained connection reset on a
            # phone is a bad time to be debugging.
            respond @notvpn "The Incus UI is reachable over the VPN only.\n" 403

            reverse_proxy https://192.168.178.200:8443 {
                transport http {
                    tls
                    # Incus presents a self-signed certificate for the host's own
                    # names, so verifying it against the name we dialled cannot
                    # succeed. Pinning to Incus's CA via tls_trusted_ca_certs and
                    # /1.0/certificates/ca would be stricter; this hop never
                    # leaves the host, so exploiting it means already owning the
                    # host. The client certificate below is what authenticates
                    # *us*, and the gate above is what authenticates the caller.
                    tls_insecure_skip_verify

                    # Rendered by apply.sh from the host's sops secrets into
                    # /var/lib/incus-secrets (the `persistent`, not-restic'd
                    # volume declared in incus.nix).
                    #
                    # `tls_client_auth`, not `tls_client_certificate`: the latter
                    # is not a transport subdirective at all and Caddy rejects the
                    # whole config with "unrecognized subdirective". Two
                    # arguments -- cert then key -- with no automate-name first,
                    # which is also rejected as a wrong argument count.
                    tls_client_auth /var/lib/incus-secrets/incus-client.crt /var/lib/incus-secrets/incus-client.key
                }
            }
        }

        # -------------------------------------------------------------------
        # ttyd.sakul-flee.de -- host-side terminal, VPN only
        # -------------------------------------------------------------------
        # Same gate shape as incus.sakul-flee.de above: `remote_ip`, not
        # `client_ip`, because the forward is DNAT and the source is
        # unforgeable while X-Forwarded-For is not. Same /10 range, matching
        # the WireGuard tunnel subnet and the Traefik vpn-only middleware.
        #
        # Plain http:// upstream: TLS terminates here and ttyd speaks plain
        # HTTP on the host. 10.0.0.1 is the host on incusbr0, so this never
        # matches the 192.168.178.200 forward and is loop-free by the same
        # asymmetry as still-traefik. ttyd's own basic auth (host sops secret)
        # is the second gate behind this one.
        #
        # A separate site block, NOT an entry in hostnames.nix: those all
        # import still-traefik.
        ttyd.sakul-flee.de {
            tls {
                dns cloudflare {env.CF_API_TOKEN}
            }

            @notvpn not remote_ip 100.64.0.0/10
            respond @notvpn "The terminal is reachable over the VPN only.\n" 403

            reverse_proxy http://10.0.0.1:7681 {
                header_up Host {http.request.host}
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
