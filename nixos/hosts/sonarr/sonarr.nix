{ config, pkgs, ... }: {
  services.sonarr = {
    enable = true;
    openFirewall = true;
  };
}
