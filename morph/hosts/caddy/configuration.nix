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
      "test.sakul-flee.de" = {
        extraConfig = ''
          respond "Test successful!"
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
