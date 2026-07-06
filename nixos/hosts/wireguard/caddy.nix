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
        reverse_proxy 10.0.0.116:5380
      }

      bitmagnet.sakul-flee.de {
      	reverse_proxy 10.0.0.114:3333
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 443 ];
}
