{
  config,
  pkgs,
  lib,
  ...
}:

let
  pluginsJarsPath = lib.cleanSource ./plugins;
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
    ./minecraft.nix
    {
      minecraftVersion = "1.21.7";
      paperBuild = "17";
      pluginsJarsSrc = pluginsJarsPath;
      memoryLimit = "8G"; # Default memory limit for the server
    }
  ];
}
