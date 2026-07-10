{ config, pkgs, ... }: {
  services.syncthing = {
    enable = true;
    guiAddress = "0.0.0.0:8384";
    openDefaultPorts = true;
    overrideDevices = false;
    overrideFolders = false;
    settings = {
      folders = {
        "/mnt/nas/personal_folder" = {
          id = "personal_folder";
          label = "Personal Folder";
          type = "sendreceive";
        };
      };
    };
  };

  # Port 8384/TCP: WebUI
  # Port 22000/TCP: TCP based sync protocol traffic
  networking.firewall.allowedTCPPorts = [ 22000 8384 ];

  # Port 22000/UDP: QUIC based sync protocol traffic
  # Port 21027/UDP: for discovery broadcasts on IPv4 and multicasts on IPv6
  networking.firewall.allowedUDPPorts = [ 22000 21027 ];
}
