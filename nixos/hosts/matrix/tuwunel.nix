{ config, pkgs, ... }: {
  services.matrix-tuwunel = {
    enable = true;
    settings.global = {
      server_name = "sakul-flee.de";
      address = [ "10.0.0.117" ];
      port = [ 6167 ];
      allow_federation = true;
      allow_registration = true;
    };
  };

  networking.firewall.allowedTCPPorts = [ 6167 ];
}
