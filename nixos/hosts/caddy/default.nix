{ config, inputs, lib, pkgs, ... }:

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
  # sops-nix itself. The host imports it via nixos/modules/sops.nix, but that
  # module also declares smb_credentials and adds sops/age/ssh-to-age to the
  # host's systemPackages; importing it here would hand this instance the whole
  # secrets surface when Caddy needs one token. Only the module is imported --
  # the secrets below are declared here and only here.
  imports = [ inputs.sops-nix.nixosModules.sops ];

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

  environment.systemPackages = with pkgs; [
    # sops decryption happens at activation, so the tools have to be here.
    # age is pulled in by sops-nix's own machinery and sops by this.
    age
    curl
    sops
    # Deliberately NOT dig: bind-tools drags in perl + boost + icu4c, roughly
    # 130MB of the image for a debugging convenience. Use `incus exec <name> --
    # curl` against an upstream, or resolve from the host instead.
    jq
  ];

  # ---------------------------------------------------------------------
  # Secrets
  # ---------------------------------------------------------------------
  #
  # sops, set up inline rather than by importing ../../modules/sops.nix. That
  # module is written for the host: it declares smb_credentials and drops sops,
  # age and ssh-to-age into systemPackages. Importing it would hand this
  # instance decryption of the entire secrets file -- restic password, Forgejo
  # JWT secret, the PIA VPN credentials -- when the only thing Caddy needs is
  # one Cloudflare token.
  #
  # So: declare exactly one secret. sops still decrypts the whole file into
  # memory, but only this key is ever written to disk, and /run is a tmpfs.
  #
  # The SSH host key is bind-mounted in from the host, read-only, by
  # hosts/caddy/incus.nix. That is a real widening of the blast radius: this
  # instance can read the host's SSH identity key. It is accepted because
  # Caddy is the component that needs a DNS-01 token and there is exactly one
  # such component. A per-instance age keypair would narrow this to just the
  # CF token, at the cost of key management and a `sops updatekeys` run
  # whenever an instance is added.
  sops = {
    defaultSopsFile = ../../secrets.yaml;
    defaultSopsFormat = "yaml";
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets.cloudflare_api_token = { };

    # The token reaches Caddy as an EnvironmentFile, not as a literal in the
    # unit. Two sops-nix details make this the only correct shape:
    #
    #   * sops.placeholder is keyed by *secret name*, not by path, and
    #   * it is only populated at all when sops.templates is non-empty.
    #
    # So the template has to exist for the placeholder to resolve, and rendering
    # it into a file is what keeps the secret out of the unit text -- a token
    # in `Environment=` would be readable by anyone who can read the unit.
    #
    # The rendered file lives in /run, which is a tmpfs, so it exists only while
    # the instance is up and never reaches the root disk.
    templates."caddy-env" = {
      content = ''
        CF_API_TOKEN=${config.sops.placeholder.cloudflare_api_token}
      '';
      mode = "0400";
      owner = "caddy";
      restartUnits = [ "caddy.service" ];
    };
  };

  # ---------------------------------------------------------------------
  # Caddy
  # ---------------------------------------------------------------------

  services.caddy = {
    enable = true;
    email = "dev@sakul-flee.de";

    # The build that has the Cloudflare DNS provider compiled in. Without this
    # the acme_dns global option below is an unknown module.
    package = caddyPkg;

    # The token arrives as an EnvironmentFile rendered by sops-nix, not as a
    # literal here. Caddy's Caddyfile reads it as {env.CF_API_TOKEN}.
    # environmentFile, not environmentFiles, and a bare path rather than a list:
    # the option is `null or absolute path`. sops renders the template to
    # /run/secrets/rendered/caddy-env, which is a tmpfs, so the token exists
    # only while the instance is up and never reaches the root disk.
    environmentFile = config.sops.templates."caddy-env".path;

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
        # tls_server_name is required: the dialled address is an IP, so without
        # it Traefik gets no SNI and serves the wrong certificate or nothing.
        (still-traefik) {
          reverse_proxy https://10.0.0.1 {
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