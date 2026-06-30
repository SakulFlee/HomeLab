{ config, pkgs, ... }: {
  services.radarr = {
    enable = true;
    openFirewall = true;
  };
}
