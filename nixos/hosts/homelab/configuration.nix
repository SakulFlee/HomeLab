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

  # NixOS firewall is disabled: k3s flannel manages iptables/nftables for pod
  # networking, and nixos-rebuild switch reloading the firewall wedged the host
  # network three times. The router (192.168.178.1) does the NAT/filtering.
  networking.firewall.enable = false;
}