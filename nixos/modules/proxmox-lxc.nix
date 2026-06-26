{ config, modulesPath, pkgs, ... }: {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  nix.settings.sandbox = false;

  proxmoxLXC = {
    manageNetwork = false;
    privileged = false;
    consoleShell = "${pkgs.bash}/bin/bash -l";
  };

  systemd.services."serial-getty@".environment.TERM = "linux";
}
