{ config, pkgs, lib, ... }: let
  matrixWellKnown = pkgs.symlinkJoin {
    name = "matrix-well-known";
    paths = [
      (pkgs.writeTextDir ".well-known/matrix/server" ''{"m.server":"matrix.sakul-flee.de:443"}'')
      (pkgs.writeTextDir ".well-known/matrix/client" ''{"m.homeserver":{"base_url":"https://matrix.sakul-flee.de"}}'')
    ];
  };
in {
  sops.defaultSopsFile = ../../secrets/caddy.sops.yaml;
  sops.secrets."caddy-env" = {};

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
      hash = "sha256-hEHgAG0F0ozHRAPuxEqLyTATBrE+pajeXDiSNwniorg=";
    };
    email = "dev@sakul-flee.de";
    environmentFile = config.sops.secrets."caddy-env".path;
    extraConfig = ''
      sakul-flee.de, www.sakul-flee.de {
        handle /.well-known/matrix/* {
            root * ${matrixWellKnown}
            file_server
        }

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

      matrix.sakul-flee.de {
        reverse_proxy 10.0.0.117:6167
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
