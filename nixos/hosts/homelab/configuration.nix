{ lib, pkgs, ... }: {
  imports = [
    ./hardware.nix
    ./kernel.nix
    ./network.nix
    ./services/_.nix
    ./common/_.nix
    ../../shared/common/_homelab.nix
    ../../users/_.nix
  ];
  custom.installPackages = false;

  # Hostname
  networking.hostName = "HomeLab";
}