{ config, pkgs, ... }: {
  sops.defaultSopsFile = ../../secrets/caddy.sops.yaml;
  sops.secrets."caddy-env" = {};

  # VPN-only reverse proxy — forwards to the public Caddy
  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
      hash = "sha256-hEHgAG0F0ozHRAPuxEqLyTATBrE+pajeXDiSNwniorg=";
    };
    globalConfig = ''
      acme_dns cloudflare {env.CF_API_TOKEN}
    '';
    environmentFile = config.sops.secrets."caddy-env".path;
    extraConfig = ''
      *.sakul-flee.de {
        reverse_proxy {
          to 10.0.0.100:443
          header_up Host {host}
          transport http {
            tls
            tls_server_name {host}
            tls_insecure_skip_verify
          }
        }
      }

      technitium.sakul-flee.de, dns.sakul-flee.de {
        header_up Host {host}
        reverse_proxy 10.0.0.116:5380
      }

      bitmagnet.sakul-flee.de {
        header_up Host {host}
      	reverse_proxy 10.0.0.114:3333
      }

      prowlarr.sakul-flee.de {
        header_up Host {host}
        reverse_proxy 10.0.0.108:9696
      }

      sonarr.sakul-flee.de {
        header_up Host {host}
        reverse_proxy 10.0.0.109:8989
      }

      radarr.sakul-flee.de {
        header_up Host {host}
        reverse_proxy 10.0.0.110:7878
      }

      qbittorrent.sakul-flee.de {
        header_up Host {host}
        reverse_proxy 10.0.0.111:8080
      }

      jellyfin.sakul-flee.de {
        header_up Host {host}
        reverse_proxy 10.0.0.107:8096
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 443 ];
}
