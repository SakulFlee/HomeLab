{ config, ... }:

{
  networking = {
    firewall = {
      enable = true;
    };

    interfaces.eth0 = {
      useDHCP = true;
    };

    defaultGateway = {
      address = "192.168.1.1";
      interface = "eth0";
    };

    nameservers = [
      "192.168.1.1"
    ];
  };
}
