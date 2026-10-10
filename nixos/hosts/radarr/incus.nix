# Incus-level definition of the "radarr" instance.
#
# See ../syncthing/incus.nix for what belongs in this file versus default.nix.
#
# Radarr manages Movies. Same three shares as sonarr -- Movies and Shows read
# (Movies is what it manages, Shows for cross-referencing), qBittorrent rw as
# the download staging area.
let
  media = import ../../modules/media-shares.nix;

  devices = {
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.108";
    };

    nas-movies = media.device "Movies" // { "raw.mount.options" = "ro"; };
    nas-shows = media.device "Shows" // { "raw.mount.options" = "ro"; };

    # Read-write: the download staging area, same as sonarr.
    qb-downloads = media.device "qBittorrent";

    radarr-config = {
      type = "disk";
      pool = "persistent";
      source = "radarr-config";
      path = "/var/lib/radarr";
    };
  };
in
{
  description = "Radarr movie manager";

  autostart = true;

  limits = {
    memory = "2GiB";
    cpu = "2";
  };

  volumes = [
    {
      pool = "persistent";
      name = "radarr-config";
      description = "Radarr state: movie database, settings, quality profiles, queue";
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;

  # VPN-gated vhost only (radarr.sakul-flee.de), no LAN forward.
}