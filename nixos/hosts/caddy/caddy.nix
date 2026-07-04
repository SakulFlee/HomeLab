{ config, pkgs, ... }: {
  services.caddy = {
    enable = true;
    email = "dev@sakul-flee.de";
    globalConfig = ''
      acme_ca https://acme.zerossl.com/v2/DV90
      acme_eab {
          key_id  kUY5FgCTebnW6EPdKbc9gw
          mac_key Gp777GdhjrW69BEF564wiw_1l7Xsq2QT1DobDpN_G32SPkVCbUEefkAJ33IBor2Qhp9Uid8DoWhyVK2aBfmADQ
      }
    '';
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

      bitmagnet.sakul-flee.de {
        reverse_proxy 10.0.0.114:3333
      }

      jellyfin.sakul-flee.de {
        reverse_proxy 10.0.0.107:8096
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
