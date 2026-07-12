{ config, pkgs, ... }: {
  services.sonarr = {
    enable = true;
    openFirewall = true;
  };

  services.restic-backup = {
    enable = true;
    paths = [ "/var/lib/sonarr" ];
  };
}
