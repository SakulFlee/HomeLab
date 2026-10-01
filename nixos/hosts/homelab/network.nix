{ ... }: {
  # ---------------------------------------------------------------------
  # The LAN address lives on a bridge, with eno1 as a bridge port
  # ---------------------------------------------------------------------
  #
  # Why: an Incus instance on a bridged NIC attaches to *a bridge*, not to a
  # bare physical NIC. `nictype = "bridged"` with `parent = eno1` does not work
  # -- Incus checks IsNativeBridge(parent), finds a bare NIC, decides the parent
  # is an OVS bridge, and fails with
  #   Failed to start device "eth0": Failed to connect to OVS
  # Because nothing on this host runs Open vSwitch. Naming the Incus *network*
  # instead (`network = "eno1"`) also fails, with "Network not found", even
  # though `incus network show eno1` lists it. So the bridge has to exist, and
  # this is it.
  #
  # This gives the wireguard VM what it needs: a real L2 peer on 192.168.178.0/24
  # that can reach 192.168.178.200, which a macvlan NIC cannot do (a macvlan
  # interface cannot talk to its own parent host) and which an incusbr0 container
  # cannot do without NAT and its masquerade rewriting every client address.
  #
  # eno1 MUST NOT carry an address or the default route. It is now a bridge port,
  # and a bridge port cannot sensibly hold either: the address would sit on the
  # wrong device and the route would be installed on a port with no L3 role.
  # That is why eno1 has no `networking.interfaces` entry at all rather than an
  # empty one -- an entry with addresses would regenerate
  # network-addresses-eno1.service and re-run `ip addr replace ... dev eno1`
  # alongside the bridge, fighting it.
  #
  # RISK. The VPN terminates on this host and the way in is 192.168.178.200. If
  # br0 comes up without that address, or eno1 is not actually enslaved, this
  # machine is unreachable from the LAN, from the internet, and therefore from
  # the VPN -- with no way back except physical or IPMI access. This is the only
  # change in the migration where failure is not recoverable remotely.
  #
  # KNOWN TRADE-OFF: IPv6. eno1 currently holds global addresses (2003:...) from
  # router advertisements. A bridge port does not accept RAs, so the router must
  # RA on br0 for those to return. The ULA fdbe::200/64 below is static and
  # unaffected. Nothing in this homelab depends on host IPv6 today; if it starts
  # mattering, `networking.interfaces.br0.ipv6.acceptRA = true` plus a router-side
  # RA on br0 is the fix.
  networking.interfaces.br0 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.178.200";
        prefixLength = 24;
      }
    ];
    ipv6.addresses = [
      {
        address = "fdbe::200";
        prefixLength = 64;
      }
    ];

  };

  # The bridge device itself, with eno1 as its port.
  #
  # `networking.bridges.<name>.interfaces` is the current spelling. The older
  # `networking.interfaces.<name>.bridgePorts` does not exist in this nixpkgs --
  # asking for it fails with
  #   The option `networking.interfaces.br0.bridgePorts' does not exist
  # and there is no forward-delay knob at all, only `rstp`.
  #
  # This lives in its own attribute rather than on networking.interfaces.br0
  # because that is where the backend looks: network-interfaces-scripted.nix
  # iterates `cfg.bridges` to emit `ip link add name br0 type bridge` and
  # `ip link set dev eno1 master br0`. The addresses above are applied by a
  # separate network-addresses-br0.service, which is what puts 192.168.178.200 on
  # the bridge rather than on eno1.
  networking.bridges.br0 = {
    interfaces = [ "eno1" ];

    # Rapid STP, default false, set explicitly for the reason above: a home LAN
    # on one switch has nothing to converge, and a bridge left in a listening
    # state would be silent unreachability on a host reached over the VPN.
    rstp = false;
  };

  # Moved off eno1 with the address. A default route on a bridge port is wrong,
  # and leaving this pointing at eno1 would keep the old route installed
  # alongside the new one.
  networking.defaultGateway = {
    address = "192.168.178.1";
    interface = "br0";
  };

  # No NetworkManager is running on this host (it is inactive, and nmcli is not
  # even installed), so this list is inert. Kept in sync anyway so that enabling
  # NM later cannot have it silently claiming these.
  networking.networkmanager.unmanaged = [
    "interface-name:eno1"
    "interface-name:br0"
  ];
}
