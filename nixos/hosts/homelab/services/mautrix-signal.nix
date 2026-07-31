{ config, pkgs, lib, ... }: {
  nixpkgs.config.permittedInsecurePackages = [
    "olm-3.2.16"
  ];

  systemd.services.mautrix-signal = {
    serviceConfig = {
      MemoryDenyWriteExecute = false;
      SystemCallFilter = [];
    };
    preStart = lib.mkAfter ''
      PICKLE_KEY_FILE="/var/lib/mautrix-signal/pickle.key"
      if [ ! -f "$PICKLE_KEY_FILE" ]; then
        (tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64) > "$PICKLE_KEY_FILE" 2>/dev/null
        chmod 600 "$PICKLE_KEY_FILE"
      fi
      PICKLE_KEY=$(cat "$PICKLE_KEY_FILE")
      export PICKLE_KEY
      ${pkgs.yq}/bin/yq -y '.encryption.pickle_key = env.PICKLE_KEY' /var/lib/mautrix-signal/config.yaml > /var/lib/mautrix-signal/config.yaml.tmp && mv /var/lib/mautrix-signal/config.yaml.tmp /var/lib/mautrix-signal/config.yaml
    '';
  };

  services.mautrix-signal = {
    enable = true;
    settings = {
      homeserver = {
        address = "http://127.0.0.1:6167";
        domain = "sakul-flee.de";
      };
      appservice = {
        hostname = "[::]";
        port = 29328;
        id = "signal";
        bot = {
          username = "signalbot";
          displayname = "Signal Bridge Bot";
        };
      };
      bridge = {
        command_prefix = "!signal";
        relay = {
          enabled = true;
        };
        permissions = {
          "sakul-flee.de" = "admin";
          "*" = "relay";
        };
        double_puppet_server_url = "https://matrix.sakul-flee.de";
        displayname_check = false;
      };
      encryption = {
        allow = true;
        default = true;
      };
      database = {
        type = "sqlite3-fk-wal";
        uri = "file:/var/lib/mautrix-signal/mautrix-signal.db?_txlock=immediate";
      };
    };
  };
}
