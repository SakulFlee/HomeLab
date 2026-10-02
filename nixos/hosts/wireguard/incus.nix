# Incus-level definition of the "wireguard" instance.
#
# This is a VM, not a container. See ../../../incus/README.md for why: WireGuard
# has to be reachable at the *host's* LAN address (192.168.178.200), and a
# container cannot route VPN clients there. A macvlan container cannot even speak
# to the host. A bridged VM is a plain L2 peer, so it can.
#
# Two files, same split as every other instance:
#   default.nix  the NixOS system, built into the image
#   incus.nix    this file -- limits, volumes and devices, plain data that
#                incus/apply.sh reads with `nix eval --json`
let
  devices = {
    # Bridged onto the physical LAN, so the VM has its own address and VPN
    # clients reach 192.168.178.200 through the router like any other peer.
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
      # machine -- 192.168.178.200 is where the router forwards UDP 51820, and
      # where the VPN that gives remote access terminates. Bridging it means
      # moving that address onto a bridge, and a bridge port cannot hold an
      # address or a route, so the window in which the host has neither is a
      # window in which the host is unreachable and unrecoverable remotely.
      #
      # macvlan adds a second logical interface on the same wire without
      # touching eno1 at all. The host keeps its address, its route and its
      # link, so there is no failure mode to design around: nixos/hosts/homelab/
      # network.nix is not modified by this, and cannot be.
      #
      # The trade is that a macvlan interface cannot talk to its own parent
      # host -- that is a kernel property, not an Incus one, and no amount of
      # configuration changes it. Nothing here needs it to. The VPN needs the
      # router to reach it and clients to reach each other, both of which are
      # ordinary LAN traffic that macvlan handles fine. The host runs no DNS or
      # database that a guest would have to reach; those belong in containers.
      nictype = "macvlan";
      parent = "eno1";

      # Pinned rather than left to Incus. The guest matches on this MAC to
      # configure its address, and an Incus-assigned MAC that changes on
      # re-create would leave the VM with an interface that has no address and
      # no error. Must match lanMac in default.nix.
      hwaddr = "00:16:3e:00:00:10";
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