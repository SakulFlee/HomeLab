{ config, pkgs, ... }: let
  matrixWellKnown = pkgs.symlinkJoin {
    name = "matrix-well-known";
    paths = [
      (pkgs.writeTextDir ".well-known/matrix/server" ''{"m.server":"matrix.sakul-flee.de:443}"'')
      (pkgs.writeTextDir ".well-known/matrix/client" ''{"m.homeserver":{"base_url":"https://matrix.sakul-flee.de"}}'')
    ];
  };

  vpnCidr = "10.100.0.0/24";
  lanCidr = "192.168.178.0/24";
in {
  sops.secrets."caddy-env" = {};

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
      hash = "sha256-hEHgAG0F0ozHRAPuxEqLyTATBrE+pajeXDiSNwniorg=";
    };
    email = "dev@sakul-flee.de";
    environmentFile = config.sops.secrets."caddy-env".path;
    globalConfig = ''
      acme_dns cloudflare {env.CF_API_TOKEN} {
        resolvers 1.1.1.1 8.8.8.8
      }
      log {
        output file /var/log/caddy/access.log {
          roll_size 100mb
          roll_keep 5
        }
        format json
      }
    '';
    extraConfig = ''
      (dns_challenge) {
        tls {
          dns cloudflare {env.CF_API_TOKEN}
          resolvers 1.1.1.1 8.8.8.8
        }
      }

      sakul-flee.de, www.sakul-flee.de {
        import dns_challenge
        handle /.well-known/matrix/* {
            root * ${matrixWellKnown}
            file_server
        }

        handle /_matrix/* {
            reverse_proxy localhost:6167
        }

        reverse_proxy localhost:8081
      }

      nas.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy 192.168.178.250:9443 {
            transport http {
              tls_insecure_skip_verify
            }
          }
        }
        handle {
          abort
        }
      }

      forgejo.sakul-flee.de {
        import dns_challenge
        reverse_proxy localhost:3002
      }

      woodpecker.sakul-flee.de {
        import dns_challenge
        reverse_proxy localhost:8000
      }

      matrix.sakul-flee.de:443, matrix.sakul-flee.de:8448 {
        reverse_proxy localhost:6167
      }

      syncthing.sakul-flee.de, sync.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:8384
        }
        handle {
          abort
        }
      }

      technitium.sakul-flee.de, dns.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:5380
        }
        handle {
          abort
        }
      }

      bitmagnet.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:3333
        }
        handle {
          abort
        }
      }

      prowlarr.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:9696
        }
        handle {
          abort
        }
      }

      sonarr.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:8989
        }
        handle {
          abort
        }
      }

      radarr.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:7878
        }
        handle {
          abort
        }
      }

      qbittorrent.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:8080
        }
        handle {
          abort
        }
      }

      qui.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:7476
        }
        handle {
          abort
        }
      }

      jellyfin.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:8096
        }
        handle {
          abort
        }
      }

      paperless.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:28981
        }
        handle {
          abort
        }
      }

      grafana.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:3003
        }
        handle {
          abort
        }
      }

      llama.sakul-flee.de, llama-swap.sakul-flee.de, llama-proxy.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:30001
        }
        handle {
          abort
        }
      }

      open-webui.sakul-flee.de, owu.sakul-flee.de, chat.sakul-flee.de {
        import dns_challenge
        @vpn client_ip ${vpnCidr} ${lanCidr}
        handle @vpn {
          reverse_proxy localhost:30002
        }
        handle {
          abort
        }
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 443 8448 ];
}
