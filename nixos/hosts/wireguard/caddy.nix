{ ... }: {
  # VPN-only reverse proxy — forwards to the public Caddy
  services.caddy = {
    enable = true;
    extraConfig = ''
      *.sakul-flee.de {
        tls internal
        reverse_proxy {
          dial 10.0.0.100:443
          transport http {
            tls
            tls_server_name {host}
            tls_insecure_skip_verify
          }
        }
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 443 ];
}
