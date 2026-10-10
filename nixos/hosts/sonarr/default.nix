# NixOS system for the Incus instance "sonarr".
#
# Sonarr (TV) from the nixpkgs services.sonarr module, running under the shared
# media instance contract. Like the k3s deployment it replaces this is a clean
# instance: no config is imported from k3s (per the port decision), so the series
# database is built by re-adding the library.
{ config, lib, pkgs, ... }:
{
  imports = [ ../../modules/media-instance.nix ];

  networking.hostName = "sonarr";

  environment.systemPackages = [ pkgs.curl ];

  # The three shares this instance mounts (see ./incus.nix): Shows and Movies
  # read-only, qBittorrent as the rw download staging area.
  mediaInstance.mountedShares = [
    "Shows"
    "Movies"
    "qBittorrent"
  ];

  # ---------------------------------------------------------------------------
  # The data directory's ownership
  # ---------------------------------------------------------------------------
  #
  # Sonarr CRASHES ON BOOT without this:
  #
  #   System.UnauthorizedAccessException: Access to the path
  #   '/var/lib/sonarr/Sentry' is denied.
  #   Non-recoverable failure, waiting for user intervention...
  #
  # and `systemctl is-active` still reports `active`, because Restart=on-failure
  # keeps it cycling in a start-limit loop rather than settling into `failed`.
  # The only honest signal is the log, or a connection that gets no answer.
  #
  # Cause: the sonarr module uses StateDirectory = "sonarr", so systemd creates
  # /var/lib/sonarr as ROOT. The service then runs as User=sonarr Group=media
  # and cannot write its own data directory -- drwx--x--x root:root.
  #
  # The radarr module in the same family does NOT have this problem: it creates
  # the directory with a tmpfiles rule carrying the right user and group, and
  # sonarr's does not. So this is the module lagging behind its sibling, not
  # anything about this deployment.
  #
  # /var/lib/sonarr is a `persistent` pool volume (see ./incus.nix), so Incus
  # creates the mountpoint itself at 0711 root:root. A tmpfiles rule fixes the
  # ownership to sonarr:media, which is what the service actually needs, and is
  # how the radarr module in this same family already does it.
  #
  # There is deliberately NO attempt to clear StateDirectory here. Two attempts
  # were wrong:
  #
  #   * The sonarr module only sets StateDirectory when dataDir is its default
  #     (/var/lib/sonarr/.config/NzbDrone), via optionalAttrs. Setting dataDir to
  #     /var/lib/sonarr already means that branch does not fire -- so nothing
  #     needed clearing.
  #   * Clearing it with `serviceConfig.StateDirectory = lib.mkForce null`
  #     rendered as a literal `StateDirectory=` line in the unit, which systemd
  #     rejects outright:
  #
  #       Loaded: bad-setting (Reason: Unit sonarr.service has a bad unit file
  #       setting.)
  #
  #     Because NixOS' systemd generator emits a null serviceConfig key as an
  #     empty assignment rather than omitting it. That broke the unit harder
  #     than the ownership problem it was meant to fix.
  #
  # So the fix is ownership only: the tmpfiles rule below, and nothing else.
  systemd.tmpfiles.rules = [
    "d /var/lib/sonarr 0755 sonarr media -"
  ];

  # ---------------------------------------------------------------------------
  # Sonarr
  # ---------------------------------------------------------------------------
  services.sonarr = {
    enable = true;
    package = pkgs.sonarr;

    # The config volume from incus.nix, mounted at the module's dataDir. The
    # module keys StateDirectory and RequiresMountsFor off this exact path.
    dataDir = "/var/lib/sonarr";

    user = "sonarr";

    # media group so writes into the rw qBittorrent share land in gid 972.
    group = "media";

    # Bind all interfaces so Caddy (over incusbr0) can reach it. The servarr
    # module's generated config binds "*" by default; stated explicitly here so
    # the intent is visible rather than inherited.
    settings.server = {
      port = 8989;
      bindaddress = "*";
    };
  };

  # Firewall stays off (media-instance.nix); the host and Caddy's VPN gate are
  # the gates. openFirewall is deliberately not set.
}