{ lib, pkgs, ... }: {
  # Default kernel is gaming focused (ZEN)
  boot.kernelPackages = pkgs.linuxPackages_zen;
}
