{ config, pkgs, lib, ... }: {
  # mautrix-whatsapp depends on olm which is marked insecure
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

  services.mautrix-whatsapp = {
    enable = true;
    settings = {
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
          allow       = true;
          default     = true;
          allow_key_sharing = true;
        };
      };
    };
  };
}
