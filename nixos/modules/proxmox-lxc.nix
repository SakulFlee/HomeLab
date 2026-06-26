{ config, modulesPath, ... }: {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  nix.settings.sandbox = false;

  proxmoxLXC = {
    manageNetwork = false;
    privileged = false;
  };

  systemd.services."serial-getty@".environment.TERM = "linux";
}
