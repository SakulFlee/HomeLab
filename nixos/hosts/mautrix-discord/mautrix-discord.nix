{ config, pkgs, lib, ... }: {
  # mautrix-discord depends on olm which is marked insecure
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

  services.mautrix-discord = {
    enable = true;
    settings = {
      appservice = {
        address = "http://10.0.0.124:29334";
        database = {
          type = "sqlite3-fk-wal";
          uri  = "file:/var/lib/mautrix-discord/mautrix-discord.db?_txlock=immediate";
        };
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
          allow_key_sharing = true;
          allow       = true;
          default     = true;
          appservice  = true;
        };
        provisioning.prefix = "/_matrix/provision";
      };
      logging.min_level = "info";
    };
  };

  networking.firewall.allowedTCPPorts = [ 29334 ];
}
