{
  config,
  pkgs,
  lib,
  ...
}:

let
  pluginsJarsPath = lib.cleanSource ../files/minecraft_plugins;
in
{
  deployment.tags = [ "minecraft" ];

  imports = [
    ../common/state.nix
    ../common/lxc.nix
    ../common/gc.nix
    ../common/networking.nix
    ../common/ssh.nix
    ../common/common_packages.nix
    ../../modules/minecraft/configuration.nix
  ];

  services.minecraft = {
    enable = true;
    version = "1.21.6";
    build = 17;
    memoryLimit = "8G";
    pluginsJarsSource = pluginsJarsPath;
  };
}
