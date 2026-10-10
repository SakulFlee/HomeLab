# Incus-level definition of the "jellyfin" instance.
#
# See ../syncthing/incus.nix for what belongs in this file versus default.nix:
# this is the container, not the software inside it -- the volume list, the
# device map (including the GPU), the limits.
#
# Every claim in this file about Incus device behaviour was MEASURED on this
# host against Incus 7.0.1 with a throwaway container, not read off a doc page.
# That mattered twice; both findings are recorded inline.
let
  media = import ../../modules/media-shares.nix;

  devices = {
    # Fixed address on incusbr0, same shape as every other instance. Caddy
    # reaches Jellyfin here. Verified free before assignment (.106; .100-.105
    # and .110 are taken -- .110 is wireguard, do not reuse it).
    eth0 = {
      type = "nic";
      name = "eth0";
      network = "incusbr0";
      "ipv4.address" = "10.0.0.106";
    };

    # -------------------------------------------------------------------------
    # The media library, bind-mounted read-only from whichever tree each share
    # resolves to (media-shares.nix `roots`; all /mnt/nas today).
    # -------------------------------------------------------------------------
    #
    # The four library shares. qBittorrent is deliberately NOT mounted: those
    # are in-progress downloads and pointing a media server at them is how it
    # indexes a .part file.
    #
    # READ-ONLY, and that is load-bearing rather than tidier. Jellyfin never
    # modifies a media file, and `ro` is the cheapest possible structural
    # statement of that: even a compromised transcode path cannot alter the
    # library.
    #
    # The source is the bindfs mirror at media.mappedMount, NOT the CIFS path.
    # A direct bind of the CIFS share into an unprivileged container reports
    # every file as the overflow id 65534, but Jellyfin writes thumbnails and
    # metadata alongside the media and so needs correct ownership to do it. The
    # mirror supplies that (container sees 0:0); `ro` on top of that means
    # Jellyfin cannot touch a media file even though it can write beside one.
    #
    # Measured: bindfs + unprivileged container -> `0 0`, WRITABLE, and files
    # still land on the NAS as 1000:972. See modules/mount-nas.nix for the
    # mechanisms that were tried first and why none of them can work.
    nas-movies = media.device "Movies" // { "raw.mount.options" = "ro"; };
    nas-shows = media.device "Shows" // { "raw.mount.options" = "ro"; };
    nas-nsfw = media.device "NSFW" // { "raw.mount.options" = "ro"; };
    nas-personal = media.device "personal_folder" // { "raw.mount.options" = "ro"; };

    # -------------------------------------------------------------------------
    # The iGPU, for VAAPI hardware transcoding.
    # -------------------------------------------------------------------------
    #
    # A BARE gpu device, with no uid/gid/mode and no idmap. This was measured,
    # not assumed, and the measurement contradicted the design:
    #
    #   $ incus config device add <c> gpu gpu
    #   $ incus exec <c> -- ls -l /dev/dri/
    #   crw-rw---- 1 root root 226,   0 card0
    #   crw-rw-rw- 1 root root 226, 128 renderD128
    #
    # renderD128 arrives 0666 -- world read/write -- so the process can open it
    # as any user and NO group mapping is needed. Incus 7.0.1's gpu device also
    # has no raw.idmap.* key at all; its uid/gid options set the owner AS SEEN
    # INSIDE the instance, which is a different thing entirely.
    #
    # So modules/media-idmap.nix's render(303) and video(26) gids are NOT what
    # makes the GPU work here. They are harmless but not load-bearing for this
    # device. media(972) is a separate question -- see the note in
    # ../modules/media-instance.nix.
    gpu = {
      type = "gpu";
    };

    # -------------------------------------------------------------------------
    # Data-bearing volumes on `persistent`, same @daily/7d snapshot policy as
    # every other instance. These are POOL volumes, not binds, and pool volumes
    # demonstrably carry ownership correctly into the container (paperless sees
    # /var/lib/paperless as 987:987) -- that is the mechanism that works, and it
    # is why config and cache are volumes while the library is a read-only bind.
    # -------------------------------------------------------------------------
    jellyfin-config = {
      type = "disk";
      pool = "persistent";
      source = "jellyfin-config";
      path = "/var/lib/jellyfin";
    };

    jellyfin-cache = {
      type = "disk";
      pool = "persistent";
      source = "jellyfin-cache";
      path = "/var/cache/jellyfin";
    };
  };
in
{
  description = "Jellyfin media server (VAAPI-transcoded, read-only library)";

  autostart = true;

  # Transcoding is bursty and CPU-heavy when VAAPI is not doing the work, and
  # the library scan is I/O- and memory-bound across the whole library.
  # 4GiB/4 CPU, adjustable live like every other instance.
  limits = {
    memory = "4GiB";
    cpu = "4";
  };

  volumes = [
    {
      pool = "persistent";
      name = "jellyfin-config";
      description = "Jellyfin state: server config, users, watch history, metadata";

      # The snapshot is the rollback for a bad config edit or a failed upgrade.
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
    {
      pool = "persistent";
      name = "jellyfin-cache";
      description = "Transcode scratch and thumbnails -- derived data, snapshot is a convenience not a rollback";
      snapshots = {
        schedule = "@daily";
        expiry = "7d";
      };
    }
  ];

  devices = devices;

  # NO networkForward. Jellyfin is reached only through Caddy's VPN-gated vhost
  # (jellyfin.sakul-flee.de), which is not wired in this phase -- k3s still
  # serves that name. Nothing puts 8096 on the LAN.
}