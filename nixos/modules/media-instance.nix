# The contract every media instance shares, so the seven of them declare it once.
#
# Imported by each media default.nix (jellyfin, qbittorrent, prowlarr, sonarr,
# radarr, qui, fansly-recorder) rather than repeating the same posture in all
# seven. This is the first shared module under modules/ that an instance
# imports -- incus-instances.nix's comment says this directory is "where the first
# shared module will land", and this is it.
#
# What belongs here is only what is true of EVERY media instance. Anything an
# individual app needs (a service block, a port, a VPN) lives in that app's own
# default.nix; see ../paperless/default.nix for the same split one level up.
#
# ---------------------------------------------------------------------------
# WHAT WAS MEASURED, because it changed this file substantially
# ---------------------------------------------------------------------------
#
# The first version of this module created a `media` group with gid 972 inside
# the container and set every share mount point to 2775 1000:972, on the theory
# that a gid mapping would make the NAS shares group-writable. Measured on this
# host against Incus 7.0.1 with a throwaway container, that theory is wrong:
#
#   $ incus config device add <c> nas disk source=/mnt/nas/Movies path=/mnt/nas/Movies
#   $ incus exec <c> -- ls -land /mnt/nas/Movies
#   drwxrwxr-x 2 65534 65534 0 /mnt/nas/Movies
#   $ incus exec <c> -- touch /mnt/nas/Movies/.probe
#   touch: /mnt/nas/Movies/.probe: Permission denied
#
# The share arrives as the overflow id with mode 0755, so the "other" bits are
# r-x and writes fail. `shift = true` does not rescue it:
#
#   Error: Failed to start device "nas": Required idmapping abilities not
#   available
#
# ...because the source is CIFS, whose mount cannot be idmapped. Incus 7.0.1 has
# no per-share uid/gid mapping on a disk device at all (the documented options
# are source/path/pool/shift/readonly/raw.mount.options/required/... -- there is
# no raw.idmap.*), so a WRITABLE NAS bind is not achievable from an unprivileged
# LXC on this host by any supported means.
#
# What DOES work is a read-only bind, and it works completely:
#
#   $ incus config device set <c> nas readonly=true
#   $ incus exec <c> -- ls /mnt/nas/Movies
#   #recycle
#   Cosmic Princess Kaguya! (2026)
#   Puella Magi Madoka Magica the Movie Part I - Beginnings (2012)
#   $ incus exec <c> -- touch /mnt/nas/Movies/.probe
#   touch: /mnt/nas/Movies/.probe: Read-only file system
#
# So: reads are fine, writes are impossible, and that is a property of Incus +
# CIFS rather than of this module. Consequently this file no longer tries to
# arrange group-writability, because there is nothing for it to arrange. The
# apps that only read (jellyfin, prowlarr, qui) are unaffected. The apps that
# need to WRITE a share (qbittorrent, sonarr, radarr) each need that solved on
# their own terms, and NOTES.md in those directories records the options.
#
# The gid 972 mapping in modules/media-idmap.nix stays as it is: it is harmless,
# it is already shipped, and the GPU measurement (renderD128 arrives 0666) means
# those mappings are not what makes the render node work either.
{ config, lib, ... }:
let
  media = import ./media-shares.nix;
in
{
  options.mediaInstance = {
    mountedShares = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Which media shares this instance mounts read-only. Declared per app so
        the container's surface matches what the app actually reads, and so this
        list stays reviewable in one place.

        It records surface, it does not create anything: the binds come from
        each app's ./incus.nix via media.device. See the header for why nothing
        is created for these paths -- they are read-only CIFS mounts and writing
        to them would mean writing to the live NAS library.
      '';
    };
  };

  # Everything that configures the system lives under `config`, not at the top
  # level. A module that declares top-level config attributes alongside an
  # `options` block is rejected outright by lib/modules.nix:
  #
  #   error: Module '.../media-instance.nix' has an unsupported attribute
  #   `networking'. This is caused by introducing a top-level `config' or
  #   `options' attribute.
  #
  # Caught by evaluating the config rather than by the build, which is why this
  # file is evaluated before anything goes near the host.
  config = {
    # Same posture as every other instance, for the same reason: the host and
    # the Incus gate are the firewalls (Caddy's VPN gate on each vhost; no media
    # app has a LAN network forward), so a second firewall in the guest would
    # only re-filter what the host already let through. qBittorrent is the
    # deliberate exception and re-enables it in its own default.nix.
    networking.firewall.enable = false;

    # Router DNS, like every other instance -- NOT the host's 192.168.178.200.
    # qBittorrent overrides this with Quad9 through its tunnel.
    networking.nameservers = [ "192.168.178.1" ];

    # Not exposed: Incus reaches each instance via exec, and no media app
    # forwards 22.
    services.openssh.enable = false;

    # ---------------------------------------------------------------------------
  # The share mount points
  # ---------------------------------------------------------------------------
  #
  # NO tmpfiles rules, deliberately. The first version of this module emitted
  # "d /mnt/nas/<share> 2775 1000 972 -" per share, which is now known to be
  # actively wrong on two counts:
  #
  #   * The mount point is a bind MOUNTED by Incus, not a directory this
  #     container owns. tmpfiles would be chmod/chown-ing the CIFS share itself
  #     -- i.e. the real NAS library, the same bytes every other reader sees.
  #   * The bind is read-only, so the tmpfiles write fails outright.
  #
  # It would also have been a genuine data-loss hazard: 2775 1000:972 applied to
  # a live CIFS share rewrites the mode of real media files' parent directories
  # as seen by every other service on the host.
  #
  # So the mount points are left exactly as Incus presents them. An app that
  # needs a writable directory of its own declares it against a pool volume,
  # which is the mechanism that demonstrably carries ownership correctly into a
  # container (paperless sees /var/lib/paperless as 987:987).
  };
}