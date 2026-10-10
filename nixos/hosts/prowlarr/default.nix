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

  # ---------------------------------------------------------------------------
  # Why this unit is overridden
  # ---------------------------------------------------------------------------
  #
  # The module hardcodes DynamicUser = true with StateDirectory = "prowlarr" and
  # no User=/Group= to override:
  #
  #   status=238/STATE_DIRECTORY
  #   prowlarr.service: Failed with result 'start-limit-hit'.
  #
  # With a dynamic user, systemd picks an ephemeral uid for the service and
  # expects to own the StateDirectory as that uid. Here dataDir is a mounted
  # `persistent` volume that already exists root:root 0700 (created by the
  # module's own tmpfiles rule), and systemd will not chown a pre-existing root
  # directory to the dynamic user -- so the service cannot access its own data
  # directory and exits immediately, hitting the start limit.
  #
  # DynamicUser is turned off and a real, persistent user/group is used instead,
  # matching what services.sonarr and services.radarr do (both have real
  # user/group options defaulting to their own name). The media group is the
  # primary group for the same reason the other *arr instances use it: the
  # qBittorrent share is group-writable by gid 972 through the bindfs mirror.
  #
  # prowlarr mounts NO media shares (see mediaInstance.mountedShares), so this
  # identity is not a privilege escalation -- it is the same posture as the
  # other *arr instances, without a dynamic uid that cannot keep state across
  # restarts.
  systemd.services.prowlarr = {
    serviceConfig = {
      # mkForce, not a plain value. The module sets DynamicUser = true at the
      # SAME priority, so a bare `DynamicUser = false` is a definition conflict
      # rather than an override:
      #
      #   error: The option
      #   `systemd.services.prowlarr.serviceConfig.DynamicUser' has conflicting
      #   definition values
      #
      # User/Group need no mkForce -- the module sets neither, since it relies
      # on DynamicUser to supply the identity.
      DynamicUser = lib.mkForce false;
      User = "prowlarr";
      Group = "media";
    };
  };

  # The prowlarr service user. Real (not dynamic) so the StateDirectory stays
  # owned across restarts, which is what a database on a mounted volume needs.
  users.users.prowlarr = {
    group = "media";
    isSystemUser = true;
  };
}