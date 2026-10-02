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
      network = "eno1";
      nictype = "bridged";

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

  # The web UI login password and its session cookie key, rendered in from the
  # host's sops secrets. The VM never sees a decryption key, only these values.
  #
  # format = "raw", not the default "env": these are bare secrets, not KEY=value
  # pairs, and WGUI_PASSWORD_FILE wants a file whose entire contents are the
  # value. Writing `PASSWORD=...` into it would make the password literally
  # "PASSWORD=...".
  #
  # 0400 root:root, the default, is correct here. wireguard-ui runs as root (it
  # needs CAP_NET_ADMIN to bring wg0 up over netlink) and nothing else in this
  # VM reads these files. caddy's PEMs need mode/group because that service drops
  # privileges; this one does not.
  renderedSecrets = [
    {
      format = "raw";
      file = "wireguard-ui-password";
      source = "/run/secrets/wireguard_ui_password";
    }
    {
      format = "raw";
      file = "wireguard-ui-session-secret";
      source = "/run/secrets/wireguard_ui_session_secret";
    }
  ];

  # wireguard-ui.service reads both of the above, and cannot start without them:
  # the password file is how the admin login is created, and the session secret
  # is passed on the command line by the wrapper in wireguard-ui.nix. So on a
  # first deploy the unit is expected to fail until apply.sh renders them and
  # restarts it. That is the same arrangement as caddy's, and it is why this
  # list exists -- without it the service would stay down until the next reboot.
  secretConsumers = [ "wireguard-ui.service" ];
}