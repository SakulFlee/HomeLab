{ config, pkgs, ... }: {
  services.syncthing = {
    enable = true;
    user = "sakulflee";
    dataDir = "/home/sakulflee/";
    configDir = "/home/sakulflee/.config/syncthing";
    guiAddress = "127.0.0.1:8384";
    openDefaultPorts = true;
    overrideDevices = false;
    overrideFolders = false;
  };

  # Port 8384/TCP: WebUI
  # Port 22000/TCP: TCP based sync protocol traffic
  networking.firewall.allowedTCPPorts = [ 22000 8384 ];

  # Port 22000/UDP: QUIC based sync protocol traffic
  # Port 21027/UDP: for discovery broadcasts on IPv4 and multicasts on IPv6
  networking.firewall.allowedUDPPorts = [ 22000 21027 ];
}
