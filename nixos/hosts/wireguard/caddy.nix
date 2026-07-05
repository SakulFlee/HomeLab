{ ... }: {
  # VPN-only reverse proxy — forwards to the public Caddy
  services.caddy = {
    enable = true;
    extraConfig = ''
      *.sakul-flee.de {
        tls internal
        reverse_proxy 10.0.0.100:80
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 443 ];
}
