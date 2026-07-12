{ config, pkgs, ... }: {
  services.radarr = {
    enable = true;
    openFirewall = true;
  };

  services.restic-backup = {
    enable = true;
    paths = [ "/var/lib/radarr" ];
  };
}
