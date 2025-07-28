{
  config,
  pkgs,
  lib,
  ...
}:

{
  deployment.tags = [ "caddy" ];

  imports = [
    ../common/state.nix
    ../common/lxc.nix
    ../common/gc.nix
    ../common/networking.nix
    ../common/ssh.nix
    ../common/common_packages.nix
  ];

  services.caddy = {
    enable = true;
    email = "dev@sakul-flee.de";
    virtualHosts = {
      "sakul-flee.de, www.sakul-flee.de, web.sakul-flee.de" = {
        extraConfig = ''
          redir "https://sakulflee.github.io"
        '';
      };
      "syncthing.sakul-flee.de" = {
        extraConfig = ''
          encode gzip 
          reverse_proxy "syncthing:8384"
        '';
      };
      "bluemap.sakul-flee.de" = {
        extraConfig = ''
          encode gzip 
          reverse_proxy "minecraft:8100"
        '';
      };
    };
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      80 # HTTP
      443 # HTTPS
    ];
  };
}
