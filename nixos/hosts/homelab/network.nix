{ ... }: {
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

  networking.networkmanager.unmanaged = [ "interface-name:eno1" ];
}
