{ config, pkgs, ... }: {
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  services.restic-backup = {
    enable = true;
    paths = [ "/var/lib/jellyfin" ];
  };
}
