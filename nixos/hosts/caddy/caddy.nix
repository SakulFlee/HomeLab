{ config, pkgs, ... }: {
  sops.defaultSopsFile = ../../secrets/caddy.sops.yaml;
  sops.secrets."caddy-env" = {};

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
      hash = "sha256-hEHgAG0F0ozHRAPuxEqLyTATBrE+pajeXDiSNwniorg=";
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

      forgejo.sakul-flee.de {
        reverse_proxy 10.0.0.102:3000
      }

      woodpecker.sakul-flee.de {
        reverse_proxy 10.0.0.103:8000
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
