{ lib, pkgs, ... }: {
  imports = [
    ./hardware.nix
    ./screen-rotation.nix
    ../../users/_.nix
    ../../shared/_.nix
    ../../shared/common/_.nix
    ../../shared/optionals/openrgb.nix
    ../../shared/optionals/vbox.nix
  ];

  # Hostname
  networking.hostName = "Evil-Donkey";
}

