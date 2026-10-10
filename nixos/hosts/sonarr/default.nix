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