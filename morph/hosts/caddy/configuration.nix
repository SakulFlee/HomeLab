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
    openFirewall = true;
    virtualHosts = {
      "test.sakul-flee.de" = {
        extraConfig = ''
          respond "Test successful!"
        '';
      };
    };
  };
}
