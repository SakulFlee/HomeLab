# NixOS system for the Incus instance "prowlarr".
#
# Prowlarr (indexer proxy) from the nixpkgs services.prowlarr module. Mounts no
# media library -- it only manages indexer definitions and proxies release
# queries -- so mediaInstance.mountedShares is empty and the module creates no
# share directories here. Clean instance; no k3s config imported.
{ config, lib, pkgs, ... }:
{
  imports = [ ../../modules/media-instance.nix ];

  networking.hostName = "prowlarr";

  environment.systemPackages = [ pkgs.curl ];

  # No shares mounted. Stated explicitly so it is a decision, not an omission:
  # the k3s manifest mounted no hostPath volumes for Prowlarr either.
  mediaInstance.mountedShares = [ ];

  services.prowlarr = {
    enable = true;
    package = pkgs.prowlarr;

    dataDir = "/var/lib/prowlarr";

    user = "prowlarr";
    group = "media";

    settings.server = {
      port = 9696;
      bindaddress = "*";
    };
  };
}