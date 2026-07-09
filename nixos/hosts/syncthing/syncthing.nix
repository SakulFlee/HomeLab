{ config, pkgs, ... }: {
  services.syncthing = {
    enable = true;
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

  networking.firewall.allowedTCPPorts = [ 8384 ];
}
