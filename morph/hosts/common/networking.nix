{ config, ... }:

{
  networking = {
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [
        22 # SSH
      ];
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
