# Incus-level definition of the "cloudflare-ddns" instance.
#
# See ../syncthing/incus.nix for what belongs in this file versus default.nix.
# Briefly: this is the container, default.nix is the software in it.
#
# A container rather than a VM, for the same reason syncthing is one:
# favonia/cloudflare-ddns is a single static Go binary that needs no kernel of
# its own, no /dev passthrough and no privilege. Its only I/O is outbound
# HTTPS.
let
  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address. The profile
    # supplies type/name/network, so the instance still gets a veth on
    # incusbr0 with NAT egress -- which is the whole point: the client detects
    # its public IPv4 by asking 1.1.1.1 what it sees, and that answer comes
    # back through this NAT as the router's WAN address. See default.nix.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.113";
    };
  };
in
{
  description = "Cloudflare DynDNS updater";

  # Start on boot, and come back after apply.sh recreates the instance. There
  # is nothing interactive here, so there is no case for opt-out autostart.
  autostart = true;

  # 256MiB/1 CPU matches hosts/dns. The client idles between checks and keeps
  # only an in-memory cache; this is headroom, not a cap anyone is expected to
  # reach.
  limits = {
    memory = "256MiB";
    cpu = "1";
  };

  devices = devices;

  # No volumes, and deliberately no snapshot policy either. Nothing here is
  # authoritative: the DNS records live in Cloudflare, and the client's cache of
  # API responses (zone ID, record IDs) is in-memory only -- v1.16.2 opens no
  # files for writing anywhere, so a restart re-reads and carries on. A recreate
  # loses nothing, so there is nothing to back up.
  #
  # That is also why the unit's ProtectSystem=strict needs no ReadWritePaths
  # escape hatch for the client's WorkingDirectory (/var/lib/cloudflare-ddns,
  # created by the module's tmpfiles entry). tmpfiles still has to make the
  # directory, because systemd chdir()s into it before exec regardless of
  # whether the process ever writes there.

  # No networkForward. This instance is a client: it dials out and nothing
  # dials in. A forward would be the only way to give it an attack surface.

  # The API token. The host materialises sops.secrets.cloudflare_api_token to
  # /run/secrets/cloudflare_api_token on a rebuild; apply.sh reads it there and
  # writes CLOUDFLARE_API_TOKEN=<value> into /var/lib/incus-secrets/ inside
  # this instance.
  #
  # Same token caddy already uses for ACME DNS-01. It needs Zone.DNS:Edit for
  # that, which is precisely what updating records needs, so this reused the
  # existing secret rather than minting a second one for the same permission.
  #
  # 0400 root:root, apply.sh's default, is correct here: services.cloudflare-ddns
  # passes this path to systemd as EnvironmentFile, and systemd opens it as root
  # before dropping to the cloudflare-ddns user. Only a file the service opens
  # *itself* (caddy's TLS client PEMs) needs a group.
  renderedSecrets = [
    {
      file = "cloudflare-ddns-env";
      env = "CLOUDFLARE_API_TOKEN";
      source = "/run/secrets/cloudflare_api_token";
    }
  ];

  # The unit that reads the file above, and the one apply.sh restarts when its
  # contents change.
  #
  # Not optional in practice: cloudflare-ddns.service has EnvironmentFile
  # pointing at that path, so on a first deploy it fails to start because the
  # file is not there yet, and only comes up once apply.sh has written it and
  # restarted the unit -- which is why apply.sh restarts unconditionally and
  # then checks `systemctl is-active`, rather than using try-restart, which
  # would be a no-op on a unit that never started.
  secretConsumers = [ "cloudflare-ddns.service" ];
}