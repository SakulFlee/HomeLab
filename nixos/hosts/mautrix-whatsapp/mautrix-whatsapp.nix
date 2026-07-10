{ config, pkgs, lib, ... }: {
  # mautrix-whatsapp depends on olm which is marked insecure
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

  services.mautrix-whatsapp = {
    enable = true;
    settings = {
      appservice = {
        address = "http://10.0.0.125:29318";
      };
      homeserver = {
        address = "http://10.0.0.117:6167";
        domain  = "sakul-flee.de";
      };
      bridge = {
        permissions = {
          "@sakulflee:sakul-flee.de" = "admin";
          "*"                         = "relay";
        };
        encryption = {
          allow = false;
          default = false;
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 29318 ];
}
}
