# Incus-level definition of the "qbittorrent" instance.
#
# See ../syncthing/incus.nix for what belongs in this file versus default.nix.
#
# qBittorrent is the one media instance with a hard security requirement: ALL of
# its traffic must go through the PIA VPN and it must never leak. Two things
# make that true here, and both are in this file and default.nix:
#
#   1. The PIA credentials reach it as a RENDERED EnvironmentFile
#      (renderedSecrets below), never as a decryption key. The instance gets two
#      opaque strings and cannot read anything else in the host's secrets.yaml.
#   2. The kill-switch and DNS pinning live in default.nix, wired to systemd
#      network namespaces so they apply BEFORE the torrent client opens a
#      socket. See that file for the actual nftables rules.
#
# Reads/writes the four library shares plus its own download staging, matching
# the k3s manifest's hostPath volumes.
let
  media = import ../../modules/media-shares.nix;

  devices = {
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.112";
    };

    # The download staging share. Read-WRITE -- this is where qBittorrent writes
    # and where it completes into. media.device resolves the source from `roots`
    # the same way every other share does.
    qb-downloads = media.device "qBittorrent";

    # The library. Read-only: qBittorrent never edits the library itself; QUI
    # does the moving/hardlinking, and the *arr apps manage their own metadata.
    # qBittorrent only needs to READ these so the torrents that seed from them
    # resolve, and ro makes that guarantee structural.
    nas-movies = media.device "Movies" // { "raw.mount.options" = "ro"; };
    nas-shows = media.device "Shows" // { "raw.mount.options" = "ro"; };
    nas-nsfw = media.device "NSFW" // { "raw.mount.options" = "ro"; };

    qbittorrent-config = {
      type = "disk";
      pool = "persistent";
      source = "qbittorrent-config";
      path = "/var/lib/qbittorrent";
    };
  };
in
{
  description = "qBittorrent, all traffic through PIA VPN (kill-switched)";

  autostart = true;

  # qBittorrent is lightweight; 1GiB/1 CPU is plenty.
  limits = {
    memory = "1GiB";
    cpu = "1";
  };

  volumes = [
    {
      pool = "persistent";
      name = "qbittorrent-config";
      description = "qBittorrent state: qBittorrent.conf, torrents table, RSS feeds, the webui password hash";

      # This volume holds the ONLY thing that must not leak: the qBittorrent
      # credentials and torrent list. The snapshot is the rollback for a bad
      # config edit. It is NOT backed up off-box by restic beyond the pool
      # snapshot -- see NOTES.md -- because the torrent list is itself sensitive
      # and the seeds are recoverable.
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;

  # The PIA credentials, rendered by the host.
  #
  # source is /run/secrets/<name>, which exists ONLY because the host declares
  # sops.secrets.<name> in modules/sops.nix and has decrypted it. Two separate
  # env lines because PIA takes the same pair twice (once to authenticate the
  # OpenVPN tunnel, once to fetch a forwarded port) -- gluetun in the k3s
  # deployment did exactly this, and so does the WireGuard+PIA setup here.
  renderedSecrets = [
    {
      file = "qb-vpn-env";
      env = "PIA_USERNAME";
      source = "/run/secrets/vpn_pia_username";
    }
    {
      file = "qb-vpn-env";
      env = "PIA_PASSWORD";
      source = "/run/secrets/vpn_pia_password";
    }
  ];

  # NO networkForward. The WebUI (8080) is reached only through Caddy's
  # VPN-gated vhost (qbittorrent.sakul-flee.de). Torrent peer ports are NOT
  # forwarded either -- PIA port forwarding means the inbound port is assigned
  # by the VPN server and only reachable through the tunnel, so exposing 6881 on
  # the LAN would be pointless AND would advertise the home IP to peers on the
  # clearnet. This is a security property, not an omission.
}