{ lib, pkgs, ... }: {
  imports = [
    ./hardware.nix
    ../../users/_.nix
    ../../shared/common/_.nix
  ];

  # Hostname
  networking.hostName = "Cindry";
}

