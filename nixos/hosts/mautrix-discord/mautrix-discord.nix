{ config, pkgs, lib, ... }: {
  # mautrix-discord depends on olm which is marked insecure
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

  services.mautrix-discord = {
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
        provisioning.prefix = "/_matrix/provision";
      };
      logging.min_level = "info";
    };
  };

  networking.firewall.allowedTCPPorts = [ 29334 ];
}
