# NixOS inside the "wireguard" VM.
#
# What is actually running: wireguard-ui (the ngoduykhanh fork, packaged in
# nixpkgs) and the kernel's own WireGuard implementation. No Docker, no
# security.privileged, no /dev/net/tun passthrough -- a VM brings its own
# kernel, which has WireGuard built in. That is the whole reason this is a VM,
# and it is why the "prefer LXC, VM if privileged is needed" rule lands here.
#
# See incus.nix for the Incus half and ../../../incus/README.md for why the
# networking is shaped this way.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.wireguard-ui;

  # The VM's own LAN address. Set in three places that must agree: here, the
  # bind address for the web UI below, and the DHCP reservation the router needs.
  # There is no single source of truth across those, which is why it is defined
  # once here and used for the two guest-side values.
  lanAddress = "192.168.178.210";

  # Must match hwaddr in incus.nix, which pins the Incus NIC's MAC so this
  # match keeps working across a re-create. An Incus-assigned MAC can change,
  # and a match on a stale MAC means an interface with no address at all --
  # a VM that booted, answered nothing, and gave no obvious reason why.
  lanMac = "00:16:3e:00:00:10";
in
{
  imports = [
    ./wireguard-ui.nix
    ./disk.nix
  ];

  networking.hostName = "wireguard";

  # ---------------------------------------------------------------------
  # Addressing
  # ---------------------------------------------------------------------
  # Configured here, not through Incus. Incus can hand a *container* a static
  # address; a guest configures its own network.
  #
  # networkd rather than networking.interfaces, for two reasons. nixpkgs no
  # longer offers any way to *match* on a MAC through networking.interfaces --
  # `match` and `matchConfig` are both gone from that submodule, and its own
  # option description now points at systemd.network.networks as the thing to
  # use instead. And the interface name is not a safe thing to hardcode: with
  # predictable names on (NixOS's default) a virtio NIC comes up as something
  # like enp1s0, not eth0, so a config keyed on the name would silently never
  # apply.
  #
  # Matching on the MAC is deterministic because incus.nix pins hwaddr, so the
  # address survives a re-create. An Incus-assigned MAC would drift, and a
  # networkd unit that matches nothing leaves the VM booted, unrouted and silent.
  networking.useNetworkd = true;

  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = lanMac;
    networkConfig = {
      Address = [ "${lanAddress}/24" ];
      Gateway = "192.168.178.1";

      # The resolver is the host's split-horizon CoreDNS, still running in k3s
      # at 192.168.178.200:53. Deliberate for now: moving the resolver in the
      # same change as the VPN would mean debugging DNS and routing together.
      # This VM is on the LAN, so it can reach it. Once DNS moves too, this
      # becomes the VM's own address.
      DNS = [ "192.168.178.200" ];
    };
  };

  # 192.168.178.210 must be outside the router's DHCP pool, or it will eventually
  # be handed to something else and the two will fight. Reserved on the router.

  # A bridged VM on the LAN, so it answers on the LAN. The web UI is bound to
  # lanAddress rather than 0.0.0.0 for the reason given in wireguard-ui.nix.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # sshd -- see the note on access paths below
      51821 # the web UI
    ];
    # The tunnel itself. This is a UDP port that nothing DNATs to it: the router
    # forwards 51820 to this address directly. See incus/README.md.
    allowedUDPPorts = [ 51820 ];
  };

  # ---------------------------------------------------------------------
  # WireGuard
  # ---------------------------------------------------------------------
  # NixOS builds this in, so the module list is here to make the dependency
  # explicit rather than incidental. This is the part a container cannot have:
  # there it would need the *host* kernel to carry the module.
  boot.kernelModules = [ "wireguard" ];

  # ---------------------------------------------------------------------
  # The web UI
  # ---------------------------------------------------------------------
  services.wireguard-ui = {
    enable = true;

    # Reachable from home and over the VPN. Nothing forwards this port from the
    # internet -- the router's only new forward is the tunnel's UDP port.
    bindAddress = "${lanAddress}:51821";

    # The tunnel's UDP port. Upstream defaults to 51820, which is also the
    # router's forward, so this matches what clients already have.
    listenPort = 51820;

    # 100.64.0.0/24 on purpose. Both allow-lists that already exist match
    # inside it -- the Traefik vpn-only middleware (100.64.0.0/10) and Caddy's
    # Incus vhost gate -- so moving the tunnel here leaves them working untouched.
    # Do not renumber without changing both.
    serverInterfaceAddresses = [ "100.64.0.1/24" ];

    # Public endpoint, written into every generated client config. Must be the
    # name and port the router forwards UDP to, not this VM's LAN address.
    endpointAddress = "wg.sakul-flee.de:51820";

    dnsServers = [ "192.168.178.200" ];

    # 1420, matching the interface the k3s deployment uses today. The upstream
    # default is 1450. An MTU change is not an error -- it is silent throughput
    # loss on a phone, which is the hardest version of this bug to notice.
    mtu = 1420;

    persistentKeepalive = 25;

    username = "admin";

    # Both rendered into this instance by incus/apply.sh from the host's sops
    # secrets. The VM never sees a decryption key -- it gets the plaintext, and
    # only these two values.
    #
    # On the root disk, not on the data volume, and that is deliberate. The data
    # volume holds the client database and must survive a re-create; the root
    # disk is wiped on re-create, which makes a missing secret *loud* -- the
    # service cannot start -- rather than silent. apply.sh re-renders and
    # restarts on the next reconcile. Putting them under the mount point would
    # mean writing them to the root disk anyway and having the mount shadow
    # them, leaving the service running on copies that stopped being current.
    passwordFile = "/var/lib/incus-secrets/wireguard-ui-password";
    sessionSecretFile = "/var/lib/incus-secrets/wireguard-ui-session-secret";
  };

  # ---------------------------------------------------------------------
  # Access
  # ---------------------------------------------------------------------
  # The flake disables sshd for containers only, so a VM keeps it -- a VM has a
  # real network and should not be reachable only through the Incus API.
  #
  # Be clear about what is and is not a way in today:
  #
  #   incus exec    works, and is the same path every container already uses.
  #   sshd          runs, but no authorized_keys is provisioned, so it is not
  #                 yet usable. Adding a key is the intended follow-up.
  #   incus console root is locked, so the console is a dead end.
  #
  # No operator account is invented here because there is no key to put in it.
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "no";
}
