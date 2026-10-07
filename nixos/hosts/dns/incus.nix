# Incus-level definition of the "dns" instance.
#
# This file describes the container, not the software inside it. Anything NixOS
# can configure belongs in default.nix, which is what gets built into the image;
# what is left is the handful of facts only Incus knows: how much CPU and RAM,
# and which devices it gets -- a bridge NIC with a fixed address, plus the two
# proxy devices that put the host's own 192.168.178.200:53 on this container.
#
# Read at build time by incus/apply.sh through the `incusInstances` flake
# output. See ../../../incus-instances.nix for the list.
let
  devices = {
    # Overrides the 'default' profile's eth0 with a fixed address. The profile
    # supplies type/name/network; only the address is added, so the instance
    # still gets a veth on incusbr0 and NAT egress.
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.53";
    };
  };
in
{
  description = "Split-horizon DNS for the homelab";

  # Start on boot, and bring it back up after apply.sh recreates it. An
  # instance that was deliberately stopped stays stopped; see apply.sh.
  autostart = true;

  # CoreDNS answering a home LAN and one VPN tunnel. 256MiB/1 CPU is headroom,
  # not a cap anyone is expected to hit; adjustable live with `incus config
  # set`, same as every other instance.
  limits = {
    memory = "256MiB";
    cpu = "1";
  };

  # No volumes. The zone is default.nix, not a database, so a recreate loses
  # nothing and there is nothing for restic to back up. Deliberately no
  # snapshot policy either: rolling back a stateless resolver is meaningless.

  # No renderedSecrets and no secretConsumers: this instance holds no secret
  # of any kind. Upstream forwarding needs no credentials.

  # ---------------------------------------------------------------------
  # The host's public entry points
  # ---------------------------------------------------------------------
  #
  # Two ports on the shared 192.168.178.200 forward, alongside caddy's
  # 80/443 and forgejo's 22. An Incus forward is keyed by (network, listen
  # address) with one port list, so there is no second forward object here
  # to conflict with caddy's -- and a proxy device cannot listen on this
  # address at all while the forward exists:
  #
  #   Device validation failed for "dns53-tcp": Listen address
  #   "192.168.178.200" conflicts with existing network forward
  #
  # apply.sh reconciles the union of every instance's ports on an address
  # (see sync_network_forward), so declaring these here neither disturbs
  # caddy's ports nor depends on caddy's spec: reconciling either instance
  # converges the same shared list, and only a port no instance claims is
  # ever removed.
  networkForward = {
    # The host's LAN address, shared with caddy's and forgejo's forwards.
    # Must match the host's own address; nothing validates that, and a
    # forward listening somewhere nothing answers is the quietest possible
    # failure.
    listenAddress = "192.168.178.200";

    # Derived from devices.eth0 above so the two cannot drift. This is the
    # default target for the ports below, which need no per-port override.
    targetAddress = devices.eth0."ipv4.address";

    # One entry per protocol, not a grouped entry: `port add` with a comma
    # list stores ONE entry that cannot be removed one port at a time later.
    ports = [
      {
        protocol = "udp";
        listenPort = 53;
      }
      {
        protocol = "tcp";
        listenPort = 53;
      }
    ];
  };

  devices = devices;
}
