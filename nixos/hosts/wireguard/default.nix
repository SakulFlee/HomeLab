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

  # The same, for the second NIC on incusbr0. See 20-incus below and eth1 in
  # incus.nix; this is why a macvlan-only VM could not resolve or reach
  # anything the host serves.
  bridgeMac = "00:16:3e:00:00:11";

  # The bridge address, and the subnet the forward rule below permits the
  # tunnel to reach. Not configurable per-direction: the rule matches on
  # destination so it does not depend on which interface the kernel calls the
  # second NIC, which is a name we would otherwise have to hardcode or guess.
  bridgeNetwork = "10.0.0.0/24";
  bridgeAddress = "10.0.0.110";
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

  # The second NIC, on incusbr0. See eth1 in incus.nix for why it exists.
  #
  # This is what makes CoreDNS (10.0.0.1), Caddy (10.0.0.100) and every other
  # container reachable from the tunnel, none of which the macvlan NIC can do:
  # macvlan cannot speak to its parent host, the router declined to proxy for
  # it, and 10.0.0.0/24 is not on the physical wire so no amount of routing on
  # this side delivers it.
  #
  # No Gateway, deliberately. This is not a path to the internet and must not
  # compete with 10-lan for the default route -- with two NICs, an autodetected
  # one here would make egress depend on the bridge coming up.
  #
  # No DNS either: this NIC's whole purpose is to be told about 10.0.0.1 as a
  # destination, not to be a source of resolvers. The resolver this VM itself
  # should use is a separate question and it stays public.
  #
  # RequiredForOnline = false for the same reason. networkd-wait-online blocking
  # on a bridge that is slow or absent would hold up the LAN path, which is the
  # one carrying UDP 51820 and must not be at the mercy of the second NIC.
  systemd.network.networks."20-incus" = {
    matchConfig.MACAddress = bridgeMac;
    networkConfig = {
      Address = [ "${bridgeAddress}/24" ];
    };
    linkConfig.RequiredForOnline = false;
  };

  # 192.168.178.210 must be outside the router's DHCP pool, or it will eventually
  # be handed to something else and the two will fight. Reserved on the router.

  # A VM on the LAN over macvlan, so it answers on the LAN. The web UI is bound
  # to lanAddress rather than 0.0.0.0 for the reason given in wireguard-ui.nix.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # sshd -- see the note on access paths below
      51821 # the web UI
    ];
    # The tunnel itself. This is a UDP port that nothing DNATs to it: the router
    # forwards 51820 to this address directly. See incus/README.md.
    allowedUDPPorts = [ 51820 ];

    # No extraForwardRules here, deliberately. This guest gets the iptables
    # backend, not nftables -- the generated firewall-start calls
    # `ip46tables -w ...` and never `nft` -- and extraForwardRules is documented
    # as nftables-only. It would have been accepted by the module and silently
    # ignored, which is the same class of failure as the x-systemd.requires
    # option earlier.
    #
    # Forwarding from the tunnel is already covered by networking.nat below, which
    # emits both halves against this backend:
    #   -A nixos-nat-post     -s 100.64.0.0/24 -o enp5s0 -j MASQUERADE
    #   -A nixos-filter-forward -s 100.64.0.0/24 -o enp5s0 -j ACCEPT
    #   -A nixos-filter-forward -m state --state RELATED,ESTABLISHED -j ACCEPT
    # Verified live with `iptables -S`, not just by reading the config.
  };

  # Without this the guest will not route at all: packets arrive on wg0 and are
  # dropped rather than forwarded, so no AllowedIPs setting on any client can
  # make the LAN reachable. It was 0 until this was set, which is why the tunnel
  # could be up and listening and still carry nothing but tunnel-internal traffic.
  #
  # `boot.kernel.sysctl`, not a `networking.ipForward`: there is no such option in
  # this nixpkgs, and sysctl is how NixOS sets it for its own components (see
  # services/kubernetes/kubelet.nix, which enables net.ipv4.ip_forward the same
  # way).
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # Masquerade, and deliberately so rather than a static route on the router.
  #
  # A client on the LAN dialling 192.168.178.x has no idea what 100.64.0.0/24 is:
  # its reply would go to the gateway, which has no route for that subnet. So the
  # return path has to be rewritten. That is also what the k3s deployment did --
  # its configmap masqueraded the pod subnet for exactly this reason -- so this
  # reproduces the arrangement already in use rather than introducing a topology
  # that would also need a change on the router.
  #
  # The cost, stated plainly: LAN hosts see traffic from a VPN client as coming
  # from 192.168.178.210, the VM's own address. Anything on the LAN doing
  # per-client accounting or access control by source IP will attribute it to the
  # VM. The alternative is a static route on the router, which preserves client
  # addresses and moves the dependency somewhere else.
  #
  # internalIPs, not internalInterfaces: the masquerade has to match the source
  # range the tunnel actually hands out (100.64.0.0/24, per
  # serverInterfaceAddresses). Matching the interface instead would masquerade
  # anything arriving on wg0, which is broader than it needs to be.
  networking.nat = {
    enable = true;
    internalIPs = [ "100.64.0.0/24" ];
    # The LAN NIC. Not left to autodetection: this VM has wg0, lo and the Incus
    # virtio NIC, and guessing wrong here silently produces no masquerade.
    externalInterface = "enp5s0";

    # One extra rule, and no masquerade. This is the whole of what the second
    # NIC needs from the firewall.
    #
    # networking.nat scopes every rule it generates to the single
    # externalInterface above -- nat-iptables.nix puts `-o ${externalInterface}`
    # on the MASQUERADE and on the forward-accept alike -- and externalInterface
    # is a string, not a list. So there is no way to say "and also forward into
    # the bridge" through the options, which is why this is a rule and not a
    # second internalIPs entry.
    #
    # extraCommands is the documented hook for exactly this, and it is
    # iptables-only ("incompatible with the nftables based nat module"), which
    # is the backend this guest uses. See the extraForwardRules note above for
    # why that distinction matters here.
    #
    # Matching on destination rather than on the egress interface is what makes
    # this robust. The second NIC's kernel name is not knowable at build time --
    # eth0 arrives as enp5s0 purely because virtio enumeration happened to land
    # there -- and a rule naming an interface that does not exist is silently
    # never added, which is the failure mode this file has been bitten by
    # twice already. 10.0.0.0/24 is only reachable through the second NIC, so
    # the destination is equivalent and cannot rot.
    #
    # No MASQUERADE here, on purpose, and this is the load-bearing decision.
    # incus/README.md reasons that "the bridged VM means its tunnel packets
    # leave eno1 un-NATted, so Caddy still sees a real 100.64.0.0/10 client
    # address and the Incus vhost gate keeps working". That was written for the
    # bridged design we abandoned; under macvlan the tunnel IS masqueraded out
    # enp5s0 above, and a VPN-only hostname would arrive at Caddy as
    # 192.168.178.210 and be rejected by the gate. Leaving the bridge path
    # un-NATted keeps the real 100.64.0.x intact. The consequence is a route on
    # the *host*, which is the router Caddy's reply actually traverses: Caddy
    # sends it to its own gateway, 10.0.0.1, and the host has to know to pass it
    # on to 10.0.0.110. That half lives in nixos/hosts/homelab/network.nix,
    # because it is the host's route, and this file does not configure the host.
    #
    # This VM needs no matching route. 100.64.0.0/24 is connected on wg0, so the
    # reply arrives addressed to an address the VM already has a route for, and
    # forwarding is the only thing missing -- which is what the rule above fixes.
    extraCommands = ''
      iptables -w -t filter -A nixos-filter-forward \
        -s 100.64.0.0/24 -d ${bridgeNetwork} -j ACCEPT
    '';

    # Symmetric, and tolerant of being a no-op: flushNat deletes and recreates
    # the chain before this runs, so on a normal stop the rule is already gone
    # and the -D has nothing to match. Without `|| true` every stop would
    # report a failure.
    extraStopCommands = ''
      iptables -w -t filter -D nixos-filter-forward \
        -s 100.64.0.0/24 -d ${bridgeNetwork} -j ACCEPT || true
    '';
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

    # Pre-filled Allowed IPs for new clients: split tunnel, not 0.0.0.0/0.
    #
    # Matches the ranges the k3s deployment used (apps/wireguard/configmap.yaml),
    # minus 10.0.0.0/24 -- see the note below.
    #
    #   192.168.178.0/24  the LAN, including the host at .200 and every hostname
    #                     that resolves to it. This is how Caddy is reached: the
    #                     container's own 10.0.0.100 is not involved, because the
    #                     split-horizon names resolve to the host's LAN address
    #                     and Caddy binds 0.0.0.0 there.
    #   100.64.0.0/10     the tunnel, and deliberately /10 rather than /24 to
    #                     match the old config: anything DNAT'd through the host
    #                     can land in that range, and the Incus vhost gate admits
    #                     100.64.0.0/10 too.
    #
    # Note the ranges are networks. 192.168.178.1/24 would match only that one
    # host, since a /24 has to start on the .0 boundary.
    #
    # No 10.0.0.0/24 here, and deliberately. It would be silently dead: this VM is
    # on macvlan and cannot reach its own parent host, so there is no usable next
    # hop into incusbr0. Measured, not assumed: `ping 192.168.178.200` from the
    # VM is 100% loss while `ping 192.168.178.1` is 0%. An AllowedIPs entry that
    # looks configured and times out is worse than one that is absent.
    #
    # Nothing needs it. Everything a client reaches is addressed on the host's LAN
    # address: Caddy binds 0.0.0.0 and answers every hostname, and anything
    # published the way Minecraft is today -- a k3s NodePort -- is bound on the
    # host directly. When a game server moves to an LXC, an Incus `proxy` device
    # puts it on the same host address and the same port, so no client config
    # changes and this stays true. 10.0.0.0/24 only ever mattered for hitting a
    # container by its bridge address, which is in-cluster debugging.
    defaultClientAllowedIPs = [
      "192.168.178.0/24"
      "100.64.0.0/10"
    ];

    # The dropdown for picking a client's tunnel address was empty without this.
    #
    # It is not a routing list: ValidateAndFixSubnetRanges drops any CIDR not
    # contained in a server interface, so this can only subdivide the tunnel
    # network. 192.168.178.0/24 and 10.0.0.0/24 here would both be discarded at
    # startup with only a log line, and the dropdown would read "No results
    # found" again -- indistinguishable from being unset.
    subnetRanges = [
      {
        name = "VPN";
        cidrs = [ "100.64.0.0/24" ];
      }
    ];

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
