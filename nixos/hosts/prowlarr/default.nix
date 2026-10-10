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

    # NO `user`, NO `group`, NO `supplementaryGroups`. services.prowlarr has
    # none of those options -- unlike services.sonarr and services.radarr,
    # which both have user/group and default them to their own name. The
    # prowlarr module hardcodes the unit's identity instead:
    #
    #   user = "root";
    #   group = "root";
    #
    # So an earlier version of this file that set `group = "media"` and
    # `supplementaryGroups = [ "media" ]` was rejected by name:
    #
    #   error: The option `services.prowlarr.group' does not exist.
    #
    # That is left as the module ships it rather than worked around. It is not
    # a privilege concern for this instance: prowlarr mounts NO media shares
    # (see mediaInstance.mountedShares above), so running as root inside gives
    # it nothing to reach -- it manages indexer definitions and proxies release
    # queries only. If that ever changes, the module's fixed identity is the
    # thing to revisit.

    settings.server = {
      port = 9696;
      bindaddress = "*";
    };
  };
}