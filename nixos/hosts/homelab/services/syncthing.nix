{ config, ... }: {
  services.syncthing = {
    enable = true;
    user = "sakulflee";
    dataDir = "/home/sakulflee/";
    configDir = "/home/sakulflee/.config/syncthing";
    guiAddress = "0.0.0.0:8384";
    openDefaultPorts = true;
    overrideDevices = false;
    overrideFolders = false;
    settings.gui = {};
  };

  networking.firewall.allowedTCPPorts = [ 22000 8384 ];
  networking.firewall.allowedUDPPorts = [ 22000 21027 ];

  services.homelab-restic = {
    enable = true;
    paths = [ "/var/lib/syncthing" ];
  };
}
