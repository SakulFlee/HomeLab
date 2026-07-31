{ config, pkgs, lib, ... }: {
  nixpkgs.config.permittedInsecurePackages = [
    "olm-3.2.16"
  ];

  systemd.services.mautrix-whatsapp = {
    serviceConfig = {
      MemoryDenyWriteExecute = false;
      SystemCallFilter = [];
    };
    preStart = lib.mkAfter ''
      PICKLE_KEY_FILE="/var/lib/mautrix-whatsapp/pickle.key"
      if [ ! -f "$PICKLE_KEY_FILE" ]; then
        (tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64) > "$PICKLE_KEY_FILE" 2>/dev/null
        chmod 600 "$PICKLE_KEY_FILE"
      fi
      PICKLE_KEY=$(cat "$PICKLE_KEY_FILE")
      export PICKLE_KEY
      ${pkgs.yq}/bin/yq -y '.encryption.pickle_key = env.PICKLE_KEY' /var/lib/mautrix-whatsapp/config.yaml > /var/lib/mautrix-whatsapp/config.yaml.tmp && mv /var/lib/mautrix-whatsapp/config.yaml.tmp /var/lib/mautrix-whatsapp/config.yaml
    '';
  };

  services.mautrix-whatsapp = {
    enable = true;
    settings = {
      homeserver = {
        address = "http://127.0.0.1:6167";
        domain = "sakul-flee.de";
      };
      appservice = {
        hostname = "[::]";
        port = 29318;
        id = "whatsapp";
        bot = {
          username = "whatsappbot";
          displayname = "WhatsApp Bridge Bot";
        };
      };
      bridge = {
        command_prefix = "!wa";
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
        uri = "file:/var/lib/mautrix-whatsapp/mautrix-whatsapp.db?_txlock=immediate";
      };
    };
  };
}
