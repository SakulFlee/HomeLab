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
  # After the first boot this is a no-op that checks for the label and exits.
  #
  # The ordering and the wantedBy are set further down, next to the mount they
  # relate to, because the two have to be read together to make sense.
  systemd.services.wireguard-data-format = {
    description = "Format the WireGuard data disk if it does not have the expected label";

    # DefaultDependencies=no drops the implicit After=basic.target that every
    # service gets, because basic.target is After=sysinit.target which is
    # After=local-fs.target -- i.e. the default is precisely the cycle this
    # arrangement exists to avoid. Nothing else is needed ahead of
    # local-fs.target; the ordering that matters is the explicit Before= below.
    unitConfig.DefaultDependencies = "no";

    before = [
      "local-fs.target"
      "shutdown.target"
    ];

    # Do not leave a half-formatted filesystem behind if the VM is powered off
    # mid-mkfs. With DefaultDependencies=no the usual Conflicts=shutdown.target
    # is not implied, so it is stated here.
    conflicts = [ "shutdown.target" ];

    # Wanted, not required, by local-fs.target: a VM with no data disk attached
    # must still boot. A failed format leaves the mount unmounted, and
    # RequiresMountsFor on the service keeps it down rather than letting it run
    # against the root disk.
    wantedBy = [ "local-fs.target" ];

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
      #
      # `logger` is util-linux too, and it was missed here: with `set -eu` a
      # missing `logger` is not a lost log line, it is exit 127 and no disk
      # formatted. It surfaced only once the unit actually ran, which is the
      # second-order consequence of the dependency below having been broken --
      # the script had never once been executed.
      findmnt=${pkgs.util-linux}/bin/findmnt
      lsblk=${pkgs.util-linux}/bin/lsblk
      logger=${pkgs.util-linux}/bin/logger
      mkfs_ext4=${pkgs.e2fsprogs}/sbin/mkfs.ext4

      by_label=/dev/disk/by-label/${label}
      if [ -e "$by_label" ]; then
        "$logger" -t wireguard-data-format "data disk already carries label ${label}, leaving it alone"
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
          "$logger" -t wireguard-data-format -p user.err \
            "no blank data disk found; leaving ${cfg.dataDir} unmounted so the service stays down"
          exit 1
          ;;
        1)
          "$logger" -t wireguard-data-format "formatting $1 as ext4 with label ${label}"
          "$mkfs_ext4" -q -L "${label}" "$1"
          ;;
        *)
          "$logger" -t wireguard-data-format -p user.err \
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
      #
      # One comma-separated string, not a list. systemd.mounts.options is typed
      # "strings concatenated with ,", so a list of them fails with
      # "not of type `strings concatenated with \",\"'". Other systemd options
      # take lists; this one does not.
      #
      # No x-systemd.* options here, and that is deliberate. Both of the ones
      # this used to carry -- x-systemd.requires= and x-systemd.device-timeout=
      # -- are implemented by systemd-fstab-generator, not by the mount unit
      # itself (src/fstab-generator/fstab-generator.c; systemd.mount(5) scopes
      # both to "an entry from /etc/fstab"). NixOS's systemd.mounts does not
      # write an fstab entry -- it writes the .mount unit directly -- so the
      # generator never runs and both options are inert. They survive only as
      # literal text in the unit's Options=, where mount(8) rejects them
      # outright.
      #
      # The failure this caused was silent and total: the format unit was never
      # pulled in, the label never appeared, the mount never mounted, and
      # wireguard-ui stayed down via RequiresMountsFor. Nothing anywhere said
      # "dependency missing" -- the disk simply looked absent. The real
      # dependency is declared below, on the format unit, where it is honoured.
      options = "nofail,noatime";

      # The dependency itself, on the mount rather than on the format unit.
      # Putting it here rather than as a systemd.services entry naming this same
      # unit is not a style choice: systemd.units merges services first and
      # mounts last (systemd.nix), so a services entry for this .mount would be
      # silently overwritten by the mount generated here.
      requires = [ "wireguard-data-format.service" ];
      after = [ "wireguard-data-format.service" ];
    }
  ];

  # The mount -> format dependency, expressed so that systemd actually honours
  # it. See the note on the mount options above for why the fstab spelling of
  # this did nothing.
  #
  # It goes on the *format* unit rather than on the mount, and that is forced:
  # systemd.units merges services first and mounts last (systemd.nix, the
  # `systemd.units = ...` definition), so a systemd.services entry naming this
  # same .mount unit would be silently overwritten by the mount generated
  # above. Ordering the format unit before the mount gets the same guarantee
  # without fighting that merge.
  #
  # local-fs.target is the real ordering constraint, not the mount. A mount unit
  # is pulled into local-fs.target, and the format has to happen before the
  # mount the label is for. The two are ordered against each other directly as
  # well, so the relationship does not depend on local-fs.target's internals.
}
