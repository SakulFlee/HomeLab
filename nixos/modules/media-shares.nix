# Where the media shares live, and which tree each one currently resolves to.
#
# Plain data in its own file, the same idiom as hosts/caddy/hostnames.nix,
# because four consumers need it and none of them should carry a private copy
# of the list:
#
#   modules/mount-nas.nix                              the CIFS mounts on the host
#   modules/mount-media.nix                            the local tree on the host
#   hosts/homelab/services/backup.nix                  what to include in the restic run
#   hosts/<app>/incus.nix  (via the `device` function)  the bind mount into each instance
#
# The local tree exists because the NAS (//192.168.178.250) is a single point of
# failure for the whole media library. Nothing is stored on it yet -- see
# `roots` below -- but the layout is real and testable, so that when a disk is
# added the migration is a string change rather than a redesign.
let
  # Ownership contract, and it is the SAME on both trees.
  #
  # On the NAS this is forced by the CIFS mount options (uid=1000 gid=972
  # file_mode=0664 dir_mode=0775). On the local tree there is nothing forcing
  # it, so modules/mount-media.nix creates the directories to match. Getting
  # them to differ would mean a share that works on one tree and fails on the
  # other, which is the whole failure mode this file exists to prevent.
  mediaUid = 1000;
  mediaGid = 972;

  # The group whose gid every media instance must be able to assume inside its
  # own namespace. See modules/media-idmap.nix for why that is a group mapping
  # and not a uid mapping.
  mediaGroup = "media";

  # Host side: the two trees.
  nasMount = "/mnt/nas";
  localMount = "/mnt/media";

  nasServer = "//192.168.178.250";

  # Path INSIDE every instance.
  #
  # It is /mnt/nas/<share> whatever `roots` says, and that is deliberate: it is
  # a path constant, not a claim about where the bytes are. Applications have
  # it baked into their libraries and root folders, so keeping it fixed is what
  # makes moving a share between trees a one-line change here with no
  # application config moving with it.
  #
  # /mnt/nas rather than something neutral because the deployments in
  # apps/media/ already spell their volumes that way, so the ports keep the
  # paths the k3s stack had.
  pathInInstance = "/mnt/nas";

  shares = [
    "Movies"
    "NSFW"
    "Shows"
    "personal_folder"
    "qBittorrent"
  ];

  # Which tree each share resolves to, HOST side. "/mnt/nas" or "/mnt/media".
  #
  # Every one is /mnt/nas today, and that is a measured decision rather than an
  # oversight. The NAS shares are:
  #
  #   Movies 73G   Shows 243G   NSFW 1.3T   qBittorrent 555G
  #
  # against sda1 at 932G with 320G available (measured 2026-10-09). Nothing in
  # the library fits, least of all the 555G "downloads" share, so moving
  # anything local is not merely deferred -- it is impossible until a disk is
  # added. The tree is provisioned now so that the alternative is real when it
  # is needed rather than a design that was never tried.
  #
  # To move a share: change its value here to "/mnt/media". Two things follow,
  # and both are worth knowing before doing it:
  #
  #   * The instance needs no change. The device source reads from here and the
  #     in-instance path is pathInInstance either way.
  #   * QUI hardlinks from the qBittorrent share into Movies. Hardlinks do not
  #     cross filesystems, and the two CIFS shares are already separate ones, so
  #     it copies today. Moving BOTH onto /mnt/media puts them on one btrfs
  #     subvolume and hardlinks start working for the first time -- which is the
  #     main reason to want the local tree.
  roots = {
    Movies = "/mnt/nas";
    NSFW = "/mnt/nas";
    Shows = "/mnt/nas";
    personal_folder = "/mnt/nas";
    qBittorrent = "/mnt/nas";
  };

  # The Incus disk device for one share, to be used in an instance's
  # `devices` map:
  #
  #   nas-shows = media.device "Shows";
  #
  # A bind mount of a host directory into a container. Unprivileged instances
  # cannot mount CIFS themselves -- an unprivileged user namespace may only
  # mount a short whitelist of filesystem types, and cifs is not on it -- so
  # this is not one option among several. It is the only way the NAS reaches an
  # LXC, and it is why the ownership contract above has to be negotiated
  # through group mappings rather than by mounting with different options
  # inside the guest.
  device =
    share:
    {
      type = "disk";
      source = "${roots.${share}}/${share}";
      path = "${pathInInstance}/${share}";
    };

  # Library shares that live on the local tree and are worth backing up.
  #
  # qBittorrent is excluded on purpose: it is re-downloadable, so an hourly
  # restic scan of it buys nothing. Everything else is not recoverable from
  # anywhere else, so it must be included wherever it is.
  localLibraryShares = builtins.filter (s: roots.${s} == localMount && s != "qBittorrent") shares;
in
{
  inherit
    mediaUid
    mediaGid
    mediaGroup
    nasMount
    localMount
    nasServer
    pathInInstance
    shares
    roots
    device
    localLibraryShares
    ;
}
