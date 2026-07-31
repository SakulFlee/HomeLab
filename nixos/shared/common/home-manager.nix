{ config, pkgs, lib, home-manager, inputs, ... }:
{
  imports = [
    home-manager.nixosModules.home-manager
  ];

  home-manager = {
    useUserPackages = true;
    useGlobalPkgs = true;

    backupFileExtension = "bak";

    extraSpecialArgs = { inherit inputs; };
  };
}
