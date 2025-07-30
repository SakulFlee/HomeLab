{
  config,
  pkgs,
  lib,
  ...
}:

{
  deployment.tags = [ "ddns" ];

  imports = [
    ../../modules/cf-ddns/configuration.nix
    ../common/state.nix
    ../common/lxc.nix
    ../common/gc.nix
    ../common/networking.nix
    ../common/ssh.nix
    ../common/common_packages.nix
  ];

  services."cloudflare-ddns".enable = true;
}
