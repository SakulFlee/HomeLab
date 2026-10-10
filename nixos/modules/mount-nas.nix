{ config, lib, pkgs, inputs, ... }:
let
  # The share list, the NAS address and the ownership ids all come from
  # modules/media-shares.nix, which is also what each media instance's
  # incus.nix and hosts/homelab/services/backup.nix read. Before this, the list
  # lived here and nowhere else, so adding a share to the library meant
  # remembering to touch the mounts, the instances and the backup paths by
  # hand.
  media = import ./media-shares.nix;

  mediaGid = media.mediaGid;

  shares = media.shares;

  nasServer = media.nasServer;

  # Where the bindfs mirror is mounted. Shared with the instances through
  # media-shares.nix's mappedMount.
  mappedMount = media.mappedMount;

  # The CIFS unit name for a share, which the bindfs unit has to follow: it
  # cannot overlay a share that is not mounted yet.
  cifsUnit = shareName: "${lib.escapeSystemdPath "${media.nasMount}/${shareName}"}.mount";

  makeMount = shareName: {
    name = "${media.nasMount}/${shareName}";
    value = {
      device = "${nasServer}/${shareName}";
      fsType = "cifs";
      options = [
        # Crucial: Link to the decrypted runtime path provided by sops-nix
        "credentials=/run/secrets/smb_credentials"

        # These three ARE the ownership contract for a share on this tree, and
        # mount-media.nix creates the local tree to match them. uid/gid are
        # forced on every file regardless of who writes it, which is what makes
        # host-side access uniform and what the bindfs layer below preserves:
        # files written through an instance still arrive here as 1000:972.
        "uid=1000"
        "gid=${toString mediaGid}"
        "file_mode=0664"
        "dir_mode=0775"

        # Automount on-demand so booting doesn't hang if the NAS is asleep
        "noauto"
        "x-systemd.automount"
        "x-systemd.idle-timeout=60" # Unmounts after inactivity
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # The bindfs mirror
  # ---------------------------------------------------------------------------
  #
  # Why this exists, because it is not an obvious thing to build and the "obvious"
  # answers are all wrong.
  #
  # An unprivileged instance's uid space is shifted: container root is host
  # 1000000. The CIFS mount forces uid=1000 gid=972, and host 1000 is OUTSIDE
  # the container's map, so a direct bind reports every file as the overflow id
  # 65534. Under dir_mode=0775 "other" is r-x, so reads work and writes fail:
  #
  #   drwxrwxr-x 2 65534 65534 /mnt/nas/Shows
  #   touch: /mnt/nas/Shows/.probe: Permission denied
  #
  # What was tried and does not work, so nobody repeats it:
  #
  #   raw.idmap.gid / .gids / .uid / raw.idmap   Incus 7.0.1: "Invalid device option"
  #   raw.lxc.lxc.id_map                         "Unknown configuration key"
  #   shift = true on a CIFS source              "Failed to setup device mount"
  #
  # The last one is the informative one: shift=true WORKS on btrfs and tmpfs
  # sources and fails only on CIFS, which isolates the kernel's lack of
  # idmapped-mount support for that filesystem as the blocker. Incus's own
  # idmapping is fine; there is simply no way to point it at a CIFS share.
  # (shiftfs, the mechanism LXC's shift historically used, is not in this kernel
  # either, so there is no fallback.)
  #
  # bindfs sidesteps all of it because FUSE needs no privileges in an
  # unprivileged container. bindfs is mounted by root on the host and so does its
  # I/O as root -- it can write the 1000:972 files -- while REPORTING the owner as
  # 1000000, which is inside the container's uid map. The container therefore
  # sees 0:0 and its root can write, and the bytes still land on the NAS as
  # 1000:972.
  #
  # Verified by hand before being written here:
  #
  #   bindfs /mnt/nas/Shows /mnt/nas-mapped --force-user=1000000 --force-group=1000000
  #   incus exec <unprivileged> -- ls -land /mnt/nas   ->  0 0
  #   incus exec <unprivileged> -- touch /mnt/nas/.probe  ->  WRITABLE
  #   ls -lan /mnt/nas/Shows/.probe (from the HOST)    ->  1000 972
  #
  # Ordering, which is the part that has to be right:
  #
  #   * After the CIFS mount. bindfs overlays a directory; the CIFS mount is
  #     noauto+automount, so this dependency is what pulls the share in.
  #   * WantedBy=multi-user.target, so the mirror is up before instances start.
  #     An instance whose device source is missing refuses to START, so an
  #     ordering race here is a container that silently does not come up.
  #   * WantedBy is used rather than RequiredBy: if the NAS is unreachable the
  #     mirror should be absent-but-recoverable, not a failed unit that blocks
  #     multi-user.target. Nothing here can fail local-fs.target -- these are
  #     services, not mounts, and the CIFS mounts themselves are noauto.
  #
  # One unit per share rather than a loop, so a single bad share names itself in
  # `systemctl status` instead of hiding inside a for-loop's exit code.
  makeBindfs = shareName: {
    name = "nas-mapped-${shareName}";
    value = {
      description = "bindfs mirror of the ${shareName} share for unprivileged containers";

      after = [ cifsUnit shareName ];
      requires = [ cifsUnit shareName ];

      wantedBy = [ "multi-user.target" ];

      path = [
        pkgs.bindfs
        pkgs.coreutils
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -eu

        src=${media.nasMount}/${shareName}
        dst=${mappedMount}/${shareName}

        install -d -m 0755 "$dst"

        # --force-user/--force-group set the REPORTED owner. 1000000 is the host
        # uid that container root maps to on this Incus (Nsid 0 -> Hostid
        # 1000000), which is what puts it inside the container's uid map instead
        # of on the overflow id.
        #
        # There is deliberately NO --mirror=<user> here. --mirror narrows the
        # mapping to one named uid, which would be the tighter answer, but the
        # uid it would name is container-local (0) and does not exist on the
        # host, so it cannot be expressed this way. Revisit if a per-app uid
        # inside the container ever needs to be distinguished; today every media
        # app that writes runs as its own container-root, and the NAS-side
        # ownership (1000:972) is unchanged either way.
        #
        # No --allow-other: bindfs adds allow_other by default, which is exactly
        # what an unprivileged container needs to read the mount. Passing
        # --allow-other is an error; only --no-allow-other exists.
        bindfs "$src" "$dst" \
          --force-user=${toString media.containerRootHostId} \
          --force-group=${toString media.containerRootHostId}
      '';
    };
  };
in
{
  # Media group for NAS access (sonarr, radarr, jellyfin, sakulflee). Declared
  # here rather than in media-shares.nix because that file is plain data, not a
  # module, and importable from a plain attrset as well as from a module.
  users.groups.media = { gid = mediaGid; };

  # Install the SMB/CIFS client utilities, and bindfs for the container mirror.
  environment.systemPackages = [
    pkgs.cifs-utils
    pkgs.bindfs
  ];

  fileSystems = builtins.listToAttrs (map makeMount shares);

  # The mirror tree itself is a plain directory, not a filesystem entry: each
  # share under it is mounted by its own bindfs unit below. tmpfiles creates the
  # mountpoints so bindfs never has to mkdir on a possibly-read-only parent, and
  # so the units stay idempotent across reboots.
  systemd.tmpfiles.rules = [
    "d ${mappedMount} 0755 root root -"
  ] ++ map (shareName: "d ${mappedMount}/${shareName} 0755 root root -") shares;

  systemd.services = builtins.listToAttrs (map makeBindfs shares);
}