{ config, modulesPath, pkgs, lib, ... }:
{
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];
  system.stateVersion = "25.05";

  virtualisation.docker.enable = true;

  environment.systemPackages = with pkgs; [
    neovim
    docker-compose
  ];

  security.sudo.wheelNeedsPassword = false;
  users.users.docker = {
    isNormalUser  = true;
    extraGroups  = [ "wheel" "networkmanager" "docker" ];
  };

  services.github-runners = {
    runner1 = {
      enable = true;
      replace = true;
      ephemeral = true;
      name = "cf-ddns";
      extraLabels = [ "nixos" "cf-ddns" ];
      url = "https://github.com/SakulFlee/HomeLab";
      tokenFile = "/var/lib/github-runner/build-token";
      user = "docker";
      group = "docker";
      extraPackages = [ pkgs.docker ];
    };
  };
}
