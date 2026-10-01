# Incus-level definition of the "caddy" instance.
#
# This file describes the container, not the software inside it. Anything NixOS
# can configure belongs in default.nix, which is what gets built into the image;
# what is left is the handful of facts only Incus knows: how much CPU and RAM,
# where its writable data lives, and which network device it gets.
#
# Read at build time by incus/apply.sh through the `incusInstances` flake
# output. See ../../../incus-instances.nix for the list.
{
  description = "Reverse proxy for everything in the homelab";

  # Start on boot, and bring it back up after apply.sh recreates it. An
  # instance that was deliberately stopped stays stopped; see apply.sh.
  autostart = true;

  # Caddy is not a memory hog, but it terminates TLS for every request on the
  # LAN and holds buffers for large uploads. 512MiB is headroom, not a cap
  # anyone has hit.
  limits = {
    memory = "512MiB";
    cpu = "2";
  };

  # ACME certificates and the on-disk config Caddy writes at runtime. On the
  # restic'd 'backup' pool because losing these means re-issuing certificates
  # from Let's Encrypt, and running into the rate limit is a genuine outage.
  # The Caddyfile itself is in the flake and is not stored here.
  volumes = [
    {
      pool = "backup";
      name = "caddy-data";
      description = "Caddy ACME certificates and runtime state";
    }
    {
      # Environment files the host renders in from its own sops secrets. Not
      # restic'd: a backed-up copy of a live API token is a liability, and
      # nothing here is irreplaceable -- apply.sh rewrites it from the host's
      # decrypted secret on every run.
      pool = "persistent";
      name = "caddy-secrets";
      description = "Host-rendered EnvironmentFiles; the only secret this instance ever sees";
    }
  ];

  # Files the host renders into this instance, from secrets the host itself
  # decrypts. incus/apply.sh reads `source` on the host and writes
  # `ENV_NAME=<value>` into `file` inside the instance.
  #
  # This is the whole of the instance's access to any secret, and it is
  # deliberately not a key. An earlier version bind-mounted the host's SSH
  # identity key and ran sops-nix inside the container, which worked and was the
  # wrong shape: it let a root process here decrypt every value in the host's
  # secrets.yaml, not just the Cloudflare token. Handing over a rendered value
  # means this instance has no decryption capability at all -- it cannot reach
  # the restic password, the Forgejo JWT secret, or the VPN credentials even if
  # it wants to.
  #
  # The price is that the token is at rest in this volume. That is the trade for
  # removing a whole-file decryption capability, and the volume is on the
  # not-restic'd pool so no copy leaves the box.
  renderedSecrets = [
    {
      file = "caddy-env";
      env = "CF_API_TOKEN";
      # Materialised by the host's sops.secrets.cloudflare_api_token.
      source = "/run/secrets/cloudflare_api_token";
    }
  ];

  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address. The profile
    # supplies type/name/network; only the address is added, so the instance
    # still gets a veth on incusbr0 and NAT egress.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.100";
    };

    caddy-data = {
      type = "disk";
      pool = "backup";
      source = "caddy-data";
      path = "/var/lib/caddy";
    };

    caddy-secrets = {
      type = "disk";
      pool = "persistent";
      source = "caddy-secrets";
      path = "/var/lib/incus-secrets";
    };
  };
}
