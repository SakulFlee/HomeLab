{ config, pkgs, lib, ... }:
let
  domain = "sakul-flee.de";
  serverName = "matrix.${domain}";
in {
  services.mautrix-discord = {
    enable = true;
    settings = {
      homeserver = {
        address = "http://localhost:8008";
        domain = serverName;
      };
      appservice = {
        hostname = "127.0.0.1";
        port = 29334;
        database = {
          type = "sqlite3-fk-wal";
          uri = "file:/var/lib/mautrix-discord/mautrix-discord.db?_txlock=immediate";
        };
      };
      bridge = {
        permissions = {
          "*" = "relay";
          "${serverName}" = "user";
        };
        encryption = {
          allow = true;
          default = true;
          require = false;
        };
      };
    };
    environmentFile = config.sops.secrets."discord_bridge_token".path;
  };

  services.mautrix-whatsapp = {
    enable = true;
    settings = {
      homeserver = {
        address = "http://localhost:8008";
        domain = serverName;
      };
      appservice = {
        hostname = "127.0.0.1";
        port = 29318;
        database = {
          type = "sqlite3-fk-wal";
          uri = "file:/var/lib/mautrix-whatsapp/mautrix-whatsapp.db?_txlock=immediate";
        };
      };
      bridge = {
        permissions = {
          "*" = "relay";
          "${serverName}" = "user";
        };
        encryption = {
          allow = true;
          default = true;
          require = false;
        };
      };
    };
    environmentFile = config.sops.secrets."whatsapp_bridge_token".path;
  };

  systemd.services.mautrix-discord = {
    serviceConfig = {
      SupplementaryGroups = [ "matrix-synapse" ];
    };
  };

  systemd.services.mautrix-whatsapp = {
    serviceConfig = {
      SupplementaryGroups = [ "matrix-synapse" ];
    };
  };
}
