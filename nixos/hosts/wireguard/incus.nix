# Incus-level definition of the "wireguard" instance.
#
# This is a VM, not a container. See ../../../incus/README.md for why: the kernel
# WireGuard module has to be available *inside*, and an LXC shares the host
# kernel, so the host would have to carry the module for a guest's benefit.
#
# Note what this file does NOT do: it does not put WireGuard on the host's LAN
# address. An earlier version of these comments claimed the VPN had to be
# reachable at 192.168.178.200, and that claim drove the whole design. It is
# false -- macvlan on eno1 gives this VM its own address, 192.168.178.210, and
# the router forwards UDP 51820 there. Reaching the *host* is a different
# question, and eth1 below is the answer to it.
#
# Two files, same split as every other instance:
#   default.nix  the NixOS system, built into the image
#   incus.nix    this file -- limits, volumes and devices, plain data that
#                incus/apply.sh reads with `nix eval --json`
let
  devices = {
    # On the physical LAN via macvlan, so the VM has its own address on the
    # wire and the router can forward UDP 51820 to it. That is 192.168.178.210,
    # reserved on the router.
    #
    # NOT nictype = "bridged" on incusbr0: that would put it behind the same
    # DNAT and NAT masquerade as the containers, which is the arrangement that
    # cost us the VPN earlier (see incus/README.md, "The host's entry points").
    #
    # The address is configured in the guest, not here. Incus can hand a
    # container a static address; it cannot configure a guest's network, so a VM
    # sets its own in default.nix.
    eth0 = {
      type = "nic";
      name = "eth0";

      # macvlan, not bridged, and deliberately.
      #
      # A bridge would be the textbook way to attach a guest to a physical LAN,
      # but eno1 is the host's only NIC and it carries the only route into this
      # machine -- 192.168.178.200 is the host's address, where Caddy terminates
      # and where the split-horizon resolver answers. Bridging it means moving
      # that address onto a bridge, and a bridge port cannot hold an address or a
      # route, so the window in which the host has neither is a window in which
      # the host is unreachable and unrecoverable remotely. That happened.
      #
      # macvlan adds a second logical interface on the same wire without
      # touching eno1 at all. The host keeps its address, its route and its
      # link, so there is no failure mode to design around: nixos/hosts/homelab/
      # network.nix is not modified by this, and cannot be.
      #
      # The trade is that a macvlan interface cannot talk to its own parent
      # host -- a kernel property, not an Incus one, and no amount of
      # configuration changes it. The router will not route around it either.
      #
      # This was originally justified by "nothing here needs it". That was wrong,
      # and it is the reason the VPN carried nothing but tunnel-internal traffic
      # for as long as it ran. The host runs CoreDNS on two addresses, and all
      # twenty hostnames resolve to the third thing it runs. eth1 below exists
      # to reach them.
      nictype = "macvlan";
      parent = "eno1";

      # Pinned rather than left to Incus. The guest matches on this MAC to
      # configure its address, and an Incus-assigned MAC that changes on
      # re-create would leave the VM with an interface that has no address and
      # no error. Must match lanMac in default.nix.
      hwaddr = "00:16:3e:00:00:10";
    };

    # The second NIC, and the one that makes the VPN actually useful.
    #
    # macvlan on eth0 is what the router reaches, and it is what keeps the WAN
    # side untouched: 192.168.178.210 is still on the LAN, still answers UDP
    # 51820, and tunnel packets still leave eno1. The cost of macvlan is that it
    # cannot speak to its own parent host -- a kernel property, not an Incus
    # one, and no configuration changes it. The router will not route around it
    # either: a `ip route add 192.168.178.200/32 via 192.168.178.1` from the VM
    # came back as an ICMP Redirect, "New nexthop: 192.168.178.200", which is
    # the router declining to proxy a destination on its own segment and
    # pointing back down the blocked path.
    #
    # That made the host unreachable, and with it CoreDNS (192.168.178.200 and
    # 10.0.0.1) and every split-horizon hostname, all of which resolve to the
    # host. So the tunnel carried nothing but tunnel-internal traffic.
    #
    # eth1 is on incusbr0, which is the bridge caddy and forgejo are already
    # on, and it costs the host nothing: incusbr0 has no physical port and eno1
    # is not in it, so nothing here can strand 192.168.178.200 the way putting
    # eno1 into a new bridge did. This is the same operation Incus performed
    # when it created those two containers -- add a veth to an existing bridge.
    #
    # Two NICs is Docker's model and Incus supports it natively: `devices` is a
    # set and each NIC sits on exactly one network.
    eth1 = {
      type = "nic";
      name = "eth1";

      network = "incusbr0";

      # Pinned for the same reason as eth0: the guest matches on this MAC to
      # configure its address. Must match bridgeMac in default.nix.
      hwaddr = "00:16:3e:00:00:11";
    };

    # A VM's extra disk is a raw block device, so this volume is `block` and the
    # guest mounts it itself. `incus/apply.sh` defaults a VM's volumes to block
    # and strips `path` from disk devices for VMs; `type` is spelled out anyway
    # because this is the one place the difference actually bites.
    wg-data = {
      type = "disk";
      pool = "persistent";
      source = "wireguard-data";
      # No path: a VM has no filesystem view of an attached disk.
    };
  };
in
{
  # The single switch that changes how this instance is built and created.
  # Omitted means container, so every existing spec keeps working.
  type = "vm";

  description = "WireGuard VPN with a web UI";

  autostart = true;

  # A headless NixOS VM with one Go binary in it. 1GiB is generous; the web UI
  # is not a database server. Not a limit anyone has hit, and it is adjustable
  # live with `incus config set`.
  limits = {
    memory = "1GiB";
    cpu = "2";
  };

  volumes = [
    {
      pool = "persistent";
      name = "wireguard-data";
      type = "block";
      description = "wireguard-ui database, client keys and generated configs -- losing this loses every client";
    }
  ];

  devices = devices;

  # No renderedSecrets, deliberately.
  #
  # Both of the secrets this used to render are dead weight for this instance:
  #
  #   wireguard_ui_password          WGUI_PASSWORD_FILE is documented upstream as
  #                                  "used for db initialization only". The admin
  #                                  user is created once, when the users table is
  #                                  empty, and its password hash is then
  #                                  authoritative. Upstream's own guidance is to
  #                                  start with the default admin/admin and change
  #                                  it in the UI once the server is up -- not to
  #                                  pre-seed a password and leave it. Rendering
  #                                  it could not keep the account in sync with
  #                                  the UI afterwards in any case: a password
  #                                  changed in the UI never round-trips back to
  #                                  sops.
  #
  #   wireguard_ui_session_secret    -session-secret is read at every start, so
  #                                  this one does work, but the UI is only
  #                                  reachable over the VPN, which needs a working
  #                                  tunnel, which needs this file to already
  #                                  exist. Rendering it needs apply.sh running
  #                                  as root before the first boot completes --
  #                                  a genuine ordering dependency for a
  #                                  convenience. Dropped, and the consequence is
  #                                  accepted: the compiled-in default is a
  #                                  constant published in the upstream source, so
  #                                  session cookies are forgeable by anyone who
  #                                  has read it. That is acceptable only because
  #                                  the UI is VPN-gated; it is not acceptable if
  #                                  this vhost is ever exposed to the LAN.
  #
  # The consequence worth stating plainly: because the password is initialised
  # from a default on first start, a fresh volume comes up as admin/admin. That
  # is the documented upstream behaviour and the reason the UI is not reachable
  # until the VPN is up.
  renderedSecrets = [ ];

  # Nothing consumes a rendered secret, so nothing needs restarting after one.
  secretConsumers = [ ];
}