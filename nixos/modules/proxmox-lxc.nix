{ config, modulesPath, pkgs, ... }: {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  nix.settings.sandbox = false;

  environment.systemPackages = with pkgs; [ git ];

  environment.variables.ENV = "/etc/profile";

  proxmoxLXC = {
    manageNetwork = false;
    privileged = false;
  };

  systemd.services."serial-getty@".environment.TERM = "linux";
}
