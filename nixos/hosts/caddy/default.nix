{ pkgs, ... }: {
  # NixOS system container for the Incus instance "caddy".
  #
  # Reverse proxy for everything in the homelab. During the migration it sits
  # in front of Traefik and forwards anything it does not recognise, so the
  # existing 18 hostnames keep working while hostnames move over one at a
  # time. See incus/instances/caddy.yaml for the instance's devices and limits.

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
  # problem entirely -- see the sops note below.
  services.openssh.enable = false;

  environment.systemPackages = with pkgs; [
    curl
    dig
    jq
  ];

  # ---------------------------------------------------------------------
  # Caddy
  # ---------------------------------------------------------------------

  services.caddy = {
    enable = true;
    email = "dev@sakul-flee.de";

    # Caddyfile is provided per-vhost in incus/instances/caddy.yaml's
    # configFile below; this block only sets what belongs to the service.
    configFile = pkgs.writeText "Caddyfile" ''
      {
        # Real client IPs, needed by the client_ip matchers that gate on LAN
        # vs VPN. Without this every request looks like it came from Incus'
        # proxy rather than from the actual client.
        servers {
          trusted_proxies static 10.0.0.0/24 192.168.178.0/24
        }
      }

      :80 {
        respond "caddy placeholder -- real vhosts land in incus/instances/caddy.yaml" 200
      }
    '';

    # The NixOS firewall is disabled (above), so this must stay off or it tries
    # to manage rules that do not exist here.
    openFirewall = false;

    # Reload rather than restart on config change: Caddy reloads its own config
    # gracefully, a restart drops in-flight connections.
    enableReload = true;
  };

  # ---------------------------------------------------------------------
  # Secrets
  # ---------------------------------------------------------------------
  #
  # Not wired up yet. Instances have no SSH host key of their own, and sops-nix
  # decrypts using one. Options, in the order they are worth considering:
  #
  #   1. Per-instance sops keypair, enrolled into .sops.yaml -- proper, but
  #      needs a `sops updatekeys` run every time an instance is added.
  #   2. Bind-mount the host's /etc/ssh/ssh_host_ed25519_key read-only, so
  #      every instance can decrypt with the identity key the host already
  #      uses. Simple, at the cost of a shared secret across instances.
  #   3. Declare the secrets on the host and bind-mount just those files in.
  #   4. Hand over the Cloudflare token at deploy time as an Incus config key.
  #
  # Deferred to the Caddy phase rather than guessed at now.

  systemd.tmpfiles.rules = [ "d /var/lib/caddy 0755 caddy caddy" ];
}