{ config, pkgs, ... }: {
  services.prowlarr = {
    enable = true;
    openFirewall = true;
  };

  services.restic-backup = {
    enable = true;
    paths = [ "/var/lib/prowlarr" ];
  };
}
