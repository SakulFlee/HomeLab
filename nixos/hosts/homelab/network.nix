{ ... }: {
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
  # `via` with no `dev`, on purpose. incusbr0 is Incus's own managed bridge --
  # its 10.0.0.1/24 is assigned by Incus, not declared here -- so naming it in
  # Nix would couple this to a device whose name and existence are Incus's to
  # decide. The kernel can resolve the next hop on its own: 10.0.0.110 is
  # reachable over exactly one interface, so there is nothing to disambiguate.
  networking.routes = [
    {
      address = "100.64.0.0/24";
      via = "10.0.0.110";
    }
  ];

  networking.networkmanager.unmanaged = [ "interface-name:eno1" ];
}
