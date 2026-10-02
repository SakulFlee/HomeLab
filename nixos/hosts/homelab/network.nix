{ pkgs, ... }:
let
  # The WireGuard VM's second-NIC address on incusbr0, and the next hop for the
  # tunnel subnet. Must match bridgeAddress in nixos/hosts/wireguard/default.nix.
  tunnelNextHop = "10.0.0.110";
in
{
  # Scope dhcpcd to the one interface that legitimately needs it.
  #
  # dhcpcd runs because networking.useDHCP is true (its module enables the client
  # when that is set, or when any listed interface sets useDHCP), and eno1 is
  # spared only by the explicit useDHCP = false below. That override protects
  # eno1 and nothing else: dhcpcd still walks every *other* interface on the
  # host and takes a lease on it, including Incus's veths, the bridges, and --
  # the one that mattered -- mac01a96716, the host-side half of the wireguard
  # VM's macvlan NIC.
  #
  # That device carries the VM's own MAC (00:16:3e:00:00:10, the pinned one),
  # so dhcpcd leased it 192.168.178.210: the same address the VM holds
  # statically, from the same MAC. Two devices answering for one IP on the LAN.
  # The journal shows it re-leasing every three hours, forever:
  #   mac01a96716: leased 192.168.178.210 for 86400 seconds
  # so this recurs rather than being a one-off from the VM's creation.
  #
  # This is not the VM's doing and not macvlan's: Incus sets no ipv4 settings
  # on that device (the spec has none), and nothing in NixOS configures it --
  # there is no network-addresses-mac01a96716.service, because it is not a
  # declared interface. dhcpcd simply found it.
  #
  # Safe for eno1 specifically, verified rather than assumed:
  #   * dhcpcd has never logged a single eno1 line this boot;
  #   * eno1's IPv6 is proto kernel_ra with a proto ra default route, i.e. the
  #     kernel's own router advertisement, plus a nodad SLAAC address and a
  #     kernel link-local -- none of it from a DHCP client;
  #   * the global useDHCP stays true, so eno1's static address and the default
  #     gateway are configured exactly as before.
  #
  # allowInterfaces, not denyInterfaces: non-null here means "deny anything not
  # matched", which also covers veths and bridges whose names are generated per
  # container and so cannot be enumerated in advance.
  networking.dhcpcd.allowInterfaces = [ "wlp2s0" ];

  networking.interfaces.eno1 = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "192.168.178.200";
      prefixLength = 24;
    }];
    ipv6.addresses = [{
      address = "fdbe::200";
      prefixLength = 64;
    }];
  };

  networking.defaultGateway = {
    address = "192.168.178.1";
    interface = "eno1";
  };

  # The tunnel subnet, via the WireGuard VM. See nixos/hosts/wireguard/incus.nix.
  #
  # The VM reaches this host's containers over its second NIC, on incusbr0, and
  # deliberately does not masquerade that traffic, so Caddy still sees the real
  # 100.64.0.x client address and the Incus vhost gate admits it. Un-NATted means
  # something in the middle has to route the replies, and for a container the
  # middle is its gateway -- 10.0.0.1, which is this host.
  #
  # Without this, Caddy hands each reply to 10.0.0.1, the host looks up
  # 100.64.0.0/24, finds only the default gateway, and sends it to the router,
  # which has never heard of the subnet. The symptom is a forward-accept that
  # appears to work and connections that never establish.
  #
  # This was first declared as networking.interfaces.incusbr0.ipv4.routes, and
  # that is the natural spelling -- the scripted backend (this host runs neither
  # NetworkManager nor networkd) accepts extra routes per interface. It was
  # wrong, and the reason is worth recording because it is not obvious.
  #
  # That generates network-addresses-incusbr0.service, WantedBy
  # sys-subsystem-net-devices-incusbr0.device. On boot that works: Incus creates
  # the bridge, the device unit appears, and the service starts. On a
  # `nixos-rebuild switch` it does not. The bridge already exists, so its
  # .device unit is already active, so systemd sees nothing to re-trigger it.
  # Meanwhile eno1's device unit *does* get a fresh job during the switch, so
  # network-addresses-eno1 restarts and re-adds the LAN address -- which is why
  # the asymmetry is invisible from the LAN and only the VPN breaks.
  #
  # Observed during the move to nixos-26.05, and worse than a route that was
  # simply never installed:
  #
  #   23:55:24 Stopping Address configuration of incusbr0...
  #   23:55:24 adding route 100.64.0.0/24... done
  #
  # That is ExecStop -- it deletes the route -- with no ExecStart to follow. The
  # running tunnel then still hands out handshakes, because those terminate at
  # the VM, but DNS replies have no path home: CoreDNS answers, the host has no
  # route for 100.64.0.0/24, and the phone sees DNS_PROBE_TIMEOUT rather than a
  # refusal. The tunnel looks healthy the whole time.
  #
  # `systemctl is-active` reports active throughout, because RemainAfterExit
  # preserves the state of the last completed run. Result=success and
  # ExecMainStatus=0 say nothing either. Do not trust them for this unit; check
  # `ip route show 100.64.0.0/24`.
  #
  # A oneshot with no device dependency replaces it. `ip route replace` is
  # idempotent, so a boot and a switch converge on the same state without
  # needing to know which one is happening.

  systemd.services.wireguard-tunnel-route = {
    description = "Route the WireGuard tunnel subnet back through the VM";

    wantedBy = [ "multi-user.target" ];
    # Incus creates incusbr0, so the bridge may not exist yet at this point.
    after = [ "incus.service" ];
    # A restart of Incus drops and recreates the bridge, which takes this route
    # with it. Wants= is not enough on its own; the route has to be re-added
    # every time Incus restarts, which is a rare but real event.
    restartTriggers = [ "incus.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    # `ip` by absolute store path, not by name.
    #
    # A hand-written script = '' runs with systemd's default PATH (/usr/local/
    # sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin), which contains no `ip`
    # on NixOS -- the binary lives in the store. So the first version of this
    # unit failed at boot with:
    #
    #   line 7: ip: command not found
    #   Main process exited, code=exited, status=127
    #
    # The generated network-addresses-* units do not have this problem because
    # NixOS sets an explicit Environment="PATH=" for them, carrying iproute2's
    # bin. Nothing does that for a hand-written script, and a unit with
    # RemainAfterExit plus wantedBy multi-user will not retry, so it stayed
    # failed and the route stayed absent while the service claimed to be wired
    # up. Same class as `logger` in nixos/hosts/wireguard/disk.nix, which needed
    # an absolute path for the same reason.
    #
    # path= would also work and is more conventional, but naming the binary
    # makes the dependency visible at the point of use.
    path = [ pkgs.iproute2 ];

    script = ''
      # replace, not add: idempotent, so re-running is safe and converging
      # rather than failing with "File exists". Fails loudly if the bridge is
      # missing rather than silently doing nothing.
      ip route replace 100.64.0.0/24 via ${tunnelNextHop} dev incusbr0 proto static
    '';
  };

  # No incusbr0 entry here. The route it used to carry is the oneshot above, and
  # declaring the interface would reintroduce the device-triggered unit -- and
  # with it the switch-time deletion. incusbr0's own 10.0.0.1/24 is assigned by
  # Incus and never needed declaring.
  #
  # The route installs even while the VM is down: the next hop is inside
  # incusbr0's own 10.0.0.0/24, so the kernel accepts it from the prefix alone
  # and only the ARP resolution waits for the VM.

  networking.networkmanager.unmanaged = [ "interface-name:eno1" ];
}
