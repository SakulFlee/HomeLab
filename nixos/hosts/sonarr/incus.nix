# Incus-level definition of the "sonarr" instance.
#
# See ../syncthing/incus.nix for what belongs in this file versus default.nix:
# this is the container, not the software inside it -- limits, volumes, devices.
#
# Sonarr manages TV (Shows). It reads Shows and Movies and writes into the
# qBittorrent share (the download staging area Radarr/qBittorrent hand off to),
# so those three are rw and the rest are not mounted at all.
let
  media = import ../../modules/media-shares.nix;

  devices = {
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.107";
    };

    # Read-only: Sonarr scans Shows and Movies and does not write to either
    # (it writes to the downloads share, below, and its own /config).
    nas-shows = media.device "Shows" // { "raw.mount.options" = "ro"; };
    nas-movies = media.device "Movies" // { "raw.mount.options" = "ro"; };

    # Read-write: the download staging area. Sonarr hands Sonarr/Radarr releases
    # to qBittorrent here; this is the "qb-downloads" hostPath in the k3s
    # manifest. rw because *arr moves/renames files as they are imported and
    # as qBittorrent completes them.
    qb-downloads = media.device "qBittorrent";

    sonarr-config = {
      type = "disk";
      pool = "persistent";
      source = "sonarr-config";
      path = "/var/lib/sonarr";
    };
  };
in
{
  description = "Sonarr TV series manager";

  autostart = true;

  # A library scan across the whole TV library is I/O- and memory-bound; the
  # steady state is idle. 2GiB/2 CPU is generous, adjustable live.
  limits = {
    memory = "2GiB";
    cpu = "2";
  };

  volumes = [
    {
      pool = "persistent";
      name = "sonarr-config";
      description = "Sonarr state: series database, settings, quality profiles, queue";

      # The snapshot is the rollback for a bad series edit or a failed upgrade.
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;

  # NO networkForward. Reached only through Caddy's VPN-gated vhost
  # (sonarr.sakul-flee.de), matching the k3s deployment's wireguard-vpn-only
  # Traefik middleware. *arr has no authentication of its own by default.
}