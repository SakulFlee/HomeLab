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
  };
}
