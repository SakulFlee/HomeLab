{ config, pkgs, lib, ... }:
let
  domain = "sakul-flee.de";
  serverName = "matrix.${domain}";
in {
  sops.defaultSopsFile = ../../secrets/matrix.sops.yaml;
  sops.secrets = {
    "registration_shared_secret" = { owner = config.services.matrix-synapse.user; };
    "signing_key" = { owner = config.services.matrix-synapse.user; };
    "discord_bridge_token" = { owner = config.services.matrix-synapse.user; };
    "whatsapp_bridge_token" = { owner = config.services.matrix-synapse.user; };
  };

  services.matrix-synapse = {
    enable = true;
    dataDir = "/var/lib/matrix-synapse";
    withJemalloc = true;

    extras = [
      "systemd"
      "postgres"
      "url-preview"
    ];

    settings = {
      server_name = serverName;
      public_baseurl = "https://${serverName}/";
      enable_registration = false;
      report_stats = false;
      url_preview_enabled = true;

      listeners = [
        {
          port = 8008;
          bind_addresses = [ "127.0.0.1" ];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [
            {
              names = [ "client" ];
              compress = true;
            }
            {
              names = [ "federation" ];
              compress = false;
            }
          ];
        }
      ];

      database = {
        name = "psycopg2";
        args = {
          host = "/run/postgresql";
          database = "matrix-synapse";
          user = "matrix-synapse";
          cp_min = 5;
          cp_max = 10;
        };
      };

      redis.enabled = false;

      presence.enabled = true;
      max_upload_size = "100M";
      max_image_pixels = "32M";
      dynamic_thumbnails = false;

      url_preview_ip_range_blacklist = [
        "10.0.0.0/8"
        "100.64.0.0/10"
        "127.0.0.0/8"
        "169.254.0.0/16"
        "172.16.0.0/12"
        "192.0.0.0/24"
        "192.0.2.0/24"
        "192.168.0.0/16"
        "192.88.99.0/24"
        "198.18.0.0/15"
        "198.51.100.0/24"
        "2001:db8::/32"
        "203.0.113.0/24"
        "224.0.0.0/4"
        "::1/128"
        "fc00::/7"
        "fe80::/10"
        "fec0::/10"
        "ff00::/8"
      ];

      trusted_key_servers = [
        {
          server_name = "matrix.org";
          verify_keys = {
            "ed25519:auto" = "Noi6WqcDj0QmPxCNQqgezwTlBKrfqehY1u2FyWP9uYw";
          };
        }
      ];

      rc_message = {
        per_second = 10;
        burst_count = 50;
      };

      rc_login = {
        address = {
          per_second = 0.17;
          burst_count = 5;
        };
        account = {
          per_second = 0.17;
          burst_count = 5;
        };
        failed_login = {
          per_second = 0.17;
          burst_count = 5;
        };
      };

      rc_federation = {
        window_size = 1000;
        sleep_limit = 10;
        sleep_delay = 500;
        reject_limit = 50;
        concurrent = 3;
      };

      event_cache_size = 25000;

      retention = {
        enabled = true;
        default_policy = {
          min_lifetime = null;
          max_lifetime = "90d";
        };
        purge_jobs = [
          {
            shortest_max_lifetime = "7d";
            longest_max_lifetime = "90d";
            interval = "1d";
          }
        ];
      };

      media_retention = {
        purge_after = "30d";
        cache_control = {
          max_cache_entry_size = "10M";
          max_cache_global_size = "1G";
        };
      };

      app_service_config_files = [
        "/var/lib/matrix-synapse/discord-bridge-registration.yaml"
        "/var/lib/matrix-synapse/whatsapp-bridge-registration.yaml"
      ];

      extraConfigFiles = [
        config.sops.secrets."signing_key".path
      ];
    };

    extraConfigFiles = [
      "/var/lib/matrix-synapse/secrets.yaml"
    ];
  };

  systemd.services.matrix-synapse = {
    preStart = lib.mkAfter ''
      cat > /var/lib/matrix-synapse/secrets.yaml << EOF
      registration_shared_secret: $(cat ${config.sops.secrets."registration_shared_secret".path})
      signing_key_path: ${config.sops.secrets."signing_key".path}
      EOF
    '';
    serviceConfig = {
      MemoryMax = "3G";
      MemoryHigh = "2G";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8008 8448 ];
}
