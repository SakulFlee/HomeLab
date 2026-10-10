# NixOS system for the Incus instance "radarr".
#
# Radarr (Movies) from the nixpkgs services.radarr module, running under the
# shared media instance contract. Clean instance; no k3s config imported.
{ config, lib, pkgs, ... }:
{
  imports = [ ../../modules/media-instance.nix ];

  networking.hostName = "radarr";

  environment.systemPackages = [ pkgs.curl ];

  mediaInstance.mountedShares = [
    "Movies"
    "Shows"
    "qBittorrent"
  ];

  services.radarr = {
    enable = true;
    package = pkgs.radarr;

    dataDir = "/var/lib/radarr";

    user = "radarr";
    group = "media";

    settings.server = {
      port = 7878;
      bindaddress = "*";
    };
  };
}