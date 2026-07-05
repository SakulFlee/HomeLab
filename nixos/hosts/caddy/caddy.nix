{ config, pkgs, ... }: {
  sops.defaultSopsFile = ../../secrets/caddy.sops.yaml;
  sops.secrets."caddy-env" = {};

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
    };
    email = "dev@sakul-flee.de";
    globalConfig = ''
      acme_dns cloudflare {env.CF_API_TOKEN}
    '';
    environmentFile = config.sops.secrets."caddy-env".path;
    extraConfig = ''
      sakul-flee.de, www.sakul-flee.de {
        reverse_proxy 10.0.0.101:80
      }

      nas.sakul-flee.de {
        reverse_proxy 192.168.178.250:9443 {
          transport http {
            tls_insecure_skip_verify
          }
        }
      }

      pve.sakul-flee.de {
        reverse_proxy 10.0.0.1:8006 {
          transport http {
            tls_insecure_skip_verify
          }
        }
      }

      pbs.sakul-flee.de {
        reverse_proxy 10.0.0.2:8007 {
          transport http {
            tls_insecure_skip_verify
          }
        }
      }

      forgejo.sakul-flee.de {
        reverse_proxy 10.0.0.102:3000
      }

      woodpecker.sakul-flee.de {
        reverse_proxy 10.0.0.103:8000
      }

      prowlarr.sakul-flee.de {
        reverse_proxy 10.0.0.108:9696
      }

      sonarr.sakul-flee.de {
        reverse_proxy 10.0.0.109:8989
      }

      radarr.sakul-flee.de {
        reverse_proxy 10.0.0.110:7878
      }

      qbittorrent.sakul-flee.de {
        reverse_proxy 10.0.0.111:8080
      }

      jellyfin.sakul-flee.de {
        reverse_proxy 10.0.0.107:8096
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
