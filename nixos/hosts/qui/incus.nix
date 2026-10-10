# Incus-level definition of the "qui" instance.
#
# See ../syncthing/incus.nix for what belongs in this file versus default.nix.
#
# QUI is the qBittorrent WebUI. It reads the qBittorrent share (where it watches
# torrent state) and the three library shares, and it HARDLINKS from the
# downloads share into Movies when a torrent is a movie. That hardlink is the
# reason the media port keeps a local tree (media-shares.nix `roots`): hardlinks
# cannot cross filesystems, and today Movies and qBittorrent are separate CIFS
# mounts so qui COPIES. When both are moved onto /mnt/media -- one btrfs
# subvolume -- the hardlink starts working. That is a property of the k3s app
# and it is preserved either way; this file just does not assume it.
let
  media = import ../../modules/media-shares.nix;

  devices = {
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.111";
    };

    # QUI watches torrent state in the qBittorrent share. Mounted at
    # /data/downloads/torrents -- the k3s manifest's mountPath -- NOT
    # /mnt/nas/qBittorrent, because QUI's own config (its root folders) refers
    # to that path and rewriting it would be rewriting baked-in application
    # config, which the whole port is designed to avoid. So the device path is
    # set explicitly here rather than using media.device, while the SOURCE is
    # still resolved from `roots` the same way.
    qb-downloads = {
      type = "disk";
      source = "${media.roots.qBittorrent}/qBittorrent";
      path = "/data/downloads/torrents";
    };

    # The library, read-only: QUI scans Movies/Shows/NSFW to resolve titles and
    # hardlink targets. ro -- it must never modify the library; a hardlink that
    # would need to write into Movies is the one case, and when both trees are
    # local that is a same-filesystem link that needs write on the DIRECTORY
    # to create the link... see NOTES.md. For the NAS case (today) it copies
    # through the rw downloads path instead, so ro is correct here.
    nas-movies = media.device "Movies" // { "raw.mount.options" = "ro"; };
    nas-shows = media.device "Shows" // { "raw.mount.options" = "ro"; };
    nas-nsfw = media.device "NSFW" // { "raw.mount.options" = "ro"; };

    qui-config = {
      type = "disk";
      pool = "persistent";
      source = "qui-config";
      path = "/config";
    };
  };
in
{
  description = "QUI qBittorrent WebUI";

  autostart = true;

  limits = {
    memory = "1GiB";
    cpu = "1";
  };

  volumes = [
    {
      pool = "persistent";
      name = "qui-config";
      description = "QUI state: its config, torrent state cache, database";
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;

  # VPN-gated vhost only (qui.sakul-flee.de), no LAN forward. QUI is the qBittorrent
  # control surface -- unauthenticated it is as sensitive as qBittorrent itself.
}