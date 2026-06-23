{ config, pkgs, ... }: {
  services.caddy = {
    enable = true;
    email = "dev@sakul-flee.de";
    extraConfig = ''
      :80 {
        header Content-Type text/plain
        respond "Hello from NixOS on CT 200!\n"
      }
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
