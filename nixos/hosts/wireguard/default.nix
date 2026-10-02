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

      # Public resolvers, NOT the host's CoreDNS at 192.168.178.200.
      #
      # This NIC is macvlan (see incus.nix for why), and a macvlan interface
      # cannot reach its own parent host -- a kernel property, not an Incus one.
      # Pointing DNS at 192.168.178.200 would leave this VM with a resolver it
      # can never query, which fails in a way that looks like DNS is broken
      # rather than like the address is unreachable.
      #
      # Nothing is lost. The host runs no service this VM needs, and clients get
      # their resolver via `dnsServers` below -- the one that actually matters for
      # split-horizon names, and it is unaffected because it travels over the
      # tunnel rather than over this NIC.
      DNS = [ "1.1.1.1" "9.9.9.9" ];
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

    # Handed to VPN clients, and reachable because it is resolved *through the
    # tunnel* -- a client has a route to 100.64.0.0/24 before it reads this -- so
    # it does not depend on this VM's LAN path and works unchanged under macvlan.
    #
    # 192.168.178.200 is still right here even though the VM cannot reach it: that
    # is the split-horizon resolver's address, and clients reach it over the VPN
    # interface, never over the VM's macvlan NIC.
    dnsServers = [ "192.168.178.200" ];

    # 1420, matching the interface the k3s deployment uses today. The upstream
    # default is 1450. An MTU change is not an error -- it is silent throughput
    # loss on a phone, which is the hardest version of this bug to notice.
    mtu = 1420;

    persistentKeepalive = 25;

    username = "admin";

    # No passwordFile and no sessionSecretFile, and neither default is set.
    #
    # Both are left unset deliberately:
    #
    #   passwordFile       WGUI_PASSWORD_FILE only seeds the admin account on the
    #                      very first start, when the users table is empty
    #                      (store/jsondb/jsondb.go). After that the stored hash is
    #                      authoritative and the file is never read again -- so it
    #                      cannot track a password changed in the UI, which is
    #                      where the password is meant to be changed. Upstream's
    #                      documented flow is exactly this: start as admin/admin,
    #                      then change it in the UI.
    #
    #   sessionSecretFile  -session-secret is read at every start, so this one
    #                      would work -- but see the note on renderedSecrets in
    #                      incus.nix. The accepted consequence of leaving it unset
    #                      is that session cookies are signed with the compiled-in
    #                      default, a constant published in the upstream source.
    #                      Safe only because the UI is VPN-gated.
  };

  # ---------------------------------------------------------------------
  # The tunnel
  # ---------------------------------------------------------------------
  # wireguard-ui is a config generator, not a WireGuard implementation. It writes
  # wg0.conf and nothing more: across the whole of v0.6.2 there is no os/exec, and
  # the single wgctrl.New() is in the read-only status page. Upstream is explicit
  # about this -- its systemd section is a wgui.path + wgui.service pair whose
  # ExecStart is `systemctl restart wg-quick@wg0.service`. The UI writes the file
  # and systemd applies it. Treating the missing interface as a bug, as I did,
  # sends you looking for a feature that is not supposed to exist.
  #
  # So: NixOS's own networking.wg-quick does the applying, which is the same
  # mechanism under a different name. Its configFile option exists for exactly
  # this case -- "a useful means of configuring WireGuard if one has an existing
  # .conf file" -- and it stages the file to /tmp/wg0.conf in ExecStart, not at
  # build time. That matters: a build-time copy could not work, because the file
  # does not exist until wireguard-ui has run. Every start re-reads it, so a
  # rebuild is never required.
  #
  # `networking.wg-quick` also brings its own PATH (wireguard-tools), the
  # modprobe, and After=network-online.target, none of which this module has to
  # arrange. The one thing it does not do is notice that the file changed, which
  # is the wgui.path unit in wireguard-ui.nix.
  networking.wg-quick.interfaces.wg0 = {
    configFile = "${config.services.wireguard-ui.configFilePath}";
    autostart = true;
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
