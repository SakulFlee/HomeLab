{ config, pkgs, lib, ... }: {
  nixpkgs.config.permittedInsecurePackages = [
    "olm-3.2.16"
  ];

  systemd.services.mautrix-discord.serviceConfig = {
    ReadWritePaths = [ "/var/lib/mautrix-discord" ];
  };

  services.mautrix-discord = {
    enable = true;
    settings = {
      homeserver = {
        address = "http://127.0.0.1:6167";
        domain = "sakul-flee.de";
      };
      appservice = {
        address = "http://localhost:29334";
        hostname = "0.0.0.0";
        port = 29334;
        database = {
          type = "sqlite3-fk-wal";
          uri = "file:/var/lib/mautrix-discord/mautrix-discord.db?_txlock=immediate";
        };
        id = "discord";
        bot = {
          username = "discordbot";
          displayname = "Discord bridge bot";
          avatar = "mxc://maunium.net/nIdEykemnwdisvHbpxflpDlC";
        };
      };
      bridge = {
        permissions = {
          "sakul-flee.de" = "full";
          "@sakulflee:sakul-flee.de" = "admin";
          "*" = "relay";
        };
        encryption = {
          allow = true;
          default = true;
        };
        displayname_check = false;
        federation = true;
      };
      logging = {
        min_level = "info";
        writers = [
          {
            type = "stdout";
            format = "pretty-colored";
            time_format = " ";
          }
        ];
      };
    };
  };
}
