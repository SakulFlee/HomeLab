# The data volume for the wireguard VM.
#
# This is a VM rather than a container partly because of how the disk works: a
# container's data volume is a filesystem Incus bind-mounts at `path`, while a
# guest gets a raw block device and mounts it itself. That is more work, and it
# is the work that keeps the client keys off the volatile root disk.
#
# Two things have to be true for this to be safe rather than merely clever:
#
#   1. The filesystem must be created exactly once, and never again over live
#      data. Hence: only format when the label is absent, and refuse to guess
#      when the candidate is ambiguous.
#   2. If the disk is absent or fails to mount, the service must NOT start on
#      the root disk with an empty database. That failure is invisible -- the UI
#      comes up, looks normal, and has lost every client. The service's
#      RequiresMountsFor is what prevents it; see wireguard-ui.nix.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.wireguard-ui;
  label = "wireguard-data";
in
{
  systemd.services.wireguard-data-format = {
    description = "Format the WireGuard data disk if it does not have the expected label";

    # Deliberately NOT wantedBy = [ "local-fs.target" ]. A local filesystem mount
    # is itself Before local-fs.target, so ordering the format service off
    # local-fs.target while also putting it before that mount is a cycle, and
    # systemd resolves it by dropping an ordering edge -- silently. The mount
    # pulls this unit in explicitly instead, via x-systemd.requires below, which
    # is a real dependency rather than a hoped-for ordering.
    #
    # After the first boot this is a no-op that checks for the label and exits.

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -eu

      # Absolute store paths, not bare names. A NixOS oneshot unit gets a PATH of
      # coreutils/findutils/grep/sed/systemd and nothing else -- util-linux is
      # not in it -- so a bare `findmnt` or `lsblk` fails with "command not
      # found" the first time this runs, which is on a fresh disk, i.e. the
      # first boot. That is exactly when nobody is watching the log.
      findmnt=${pkgs.util-linux}/bin/findmnt
      lsblk=${pkgs.util-linux}/bin/lsblk
      mkfs_ext4=${pkgs.e2fsprogs}/sbin/mkfs.ext4

      by_label=/dev/disk/by-label/${label}
      if [ -e "$by_label" ]; then
        logger -t wireguard-data-format "data disk already carries label ${label}, leaving it alone"
        exit 0
      fi

      # Identify the root disk and never touch it. Without this the loop below
      # could pick /dev/vda and format the filesystem this script is running on.
      root_src=$("$findmnt" -n -o SOURCE /)
      root_disk=""
      if [ -b "$root_src" ]; then
        root_disk=$("$lsblk" -ndo PKNAME "$root_src" 2>/dev/null || true)
      fi

      candidates=""
      for d in /dev/disk/by-id/virtio-* /dev/vd? /dev/nvme?n? /dev/sd?; do
        [ -b "$d" ] || continue
        # Resolve to the kernel's own name before anything else. The glob above
        # deliberately lists both a by-id symlink and the /dev node, so the same
        # disk arrives twice -- and then $# is 2, the case below takes the
        # "refusing to guess" branch, and the disk this script exists to format
        # is the one it refuses. That is a fresh-disk bug, so it would bite on
        # exactly the first boot and never again.
        r=$(readlink -f "$d")
        [ -n "$root_disk" ] && [ "$r" = "/dev/$root_disk" ] && continue
        case " $candidates " in
          *" $r "*) continue ;;
        esac
        # A blank disk has no children. Anything reporting a partition, LVM or
        # crypt device is in use and is not ours to format.
        if "$lsblk" -nrpo TYPE "$r" 2>/dev/null | grep -qvE '^disk$'; then
          continue
        fi
        candidates="$candidates $r"
      done

      # shellcheck disable=SC2086
      set -- $candidates
      case $# in
        0)
          logger -t wireguard-data-format -p user.err \
            "no blank data disk found; leaving ${cfg.dataDir} unmounted so the service stays down"
          exit 1
          ;;
        1)
          logger -t wireguard-data-format "formatting $1 as ext4 with label ${label}"
          "$mkfs_ext4" -q -L "${label}" "$1"
          ;;
        *)
          logger -t wireguard-data-format -p user.err \
            "more than one blank disk ($*) -- refusing to guess"
          exit 1
          ;;
      esac
    '';
  };

  systemd.mounts = [
    {
      what = "/dev/disk/by-label/${label}";
      where = cfg.dataDir;

      # The option is `type`, not `fsType`. `fsType` is what fileSystems.* uses,
      # and mixing the two up here fails with "option ...fsType does not exist".
      type = "ext4";

      # nofail, because a VM with no data disk attached should still boot --
      # you need to be able to log in and fix it. The cost is that the mount is
      # not strictly required for boot; the service's RequiresMountsFor is what
      # actually keeps the service off the root disk.
      # One comma-separated string, not a list. systemd.mounts.options is typed
      # "strings concatenated with ,", so a list of them fails with
      # "not of type `strings concatenated with \",\"'". Other systemd options
      # take lists; this one does not.
      options = "nofail,noatime,x-systemd.device-timeout=10s,x-systemd.requires=wireguard-data-format.service";
    }
  ];
}
