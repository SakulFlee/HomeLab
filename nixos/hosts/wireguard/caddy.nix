{ ... }: {
  # VPN-only reverse proxy — forwards to the public Caddy
  services.caddy = {
    enable = true;
    extraConfig = ''
      *.sakul-flee.de {
        tls internal
        reverse_proxy https://10.0.0.100 {
          transport http {
            tls_insecure_skip_verify
          }
        }
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 443 ];
}
