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

    # The host's own 192.168.178.200:53, served by this container.
    #
    # A proxy device, not a network forward: a forward carries one
    # targetAddress for the whole listen address, and 192.168.178.200 is
    # already claimed by caddy's forward (ports 80/443 -> 10.0.0.100). A
    # second forward object cannot share the listen address, but proxy
    # devices attach per-instance and coexist with it.
    #
    # Minimal keys on purpose: listen + connect are the only required ones,
    # and sync_devices matches by subset, so anything Incus defaults in is
    # tolerated rather than fought over on every run. Source rewriting by
    # the proxy is irrelevant here -- split-horizon answers do not depend on
    # the client address, unlike Caddy's VPN gate.
    #
    # One entry per protocol, same reason as caddy's forward ports: grouped
    # entries cannot be managed one at a time later.
    dns53-udp = {
      type = "proxy";
      listen = "udp:192.168.178.200:53";
      connect = "udp:10.0.0.53:53";
    };
    dns53-tcp = {
      type = "proxy";
      listen = "tcp:192.168.178.200:53";
      connect = "tcp:10.0.0.53:53";
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

  devices = devices;
}
