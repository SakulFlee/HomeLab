{ config, pkgs, lib, ... }:
let
  domain = "sakul-flee.de";
  serverName = "matrix.${domain}";
  elementWebConfig = {
    default_server_config = {
      "m.homeserver" = {
        base_url = "https://${serverName}";
        server_name = domain;
      };
      "m.identity_server" = {
        base_url = "https://vector.im";
      };
    };
    brand = "Element";
    default_theme = "dark";
    room_directory = {
      servers = [ domain ];
    };
    disable_custom_css = false;
    features = {
      feature_mathjax = false;
      feature_voice_messages = false;
      feature_video_rooms = true;
    };
  };
  elementWebConfigFile = pkgs.writeText "config.json" (builtins.toJSON elementWebConfig);
in {
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;

    virtualHosts."element.${domain}" = {
      forceSSL = false;
      listen = [
        {
          addr = "127.0.0.1";
          port = 8080;
        }
      ];

      root = pkgs.element-web + "/share/element-web";

      extraConfig = ''
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;

        location / {
          try_files $uri $uri/ /index.html;
        }

        location /config.json {
          alias ${elementWebConfigFile};
          add_header Cache-Control "no-cache, no-store, must-revalidate";
        }

        location /config.*.json {
          add_header Cache-Control "no-cache, no-store, must-revalidate";
        }
      '';
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
