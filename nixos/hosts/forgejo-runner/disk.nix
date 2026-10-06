# The data volume for the forgejo-runner VM.
#
# Same arrangement as the wireguard VM's disk (hosts/wireguard/disk.nix),
# for the same reason: a container's data volume is a filesystem Incus
# bind-mounts at `path`, while a guest gets a raw block device and mounts
# it itself. The extra work is what keeps the runner's state -- the
# actions cache, the job workspaces, and the generated config.yaml, which
# holds the runner token -- off the volatile root disk. A re-create
# replaces the root disk and nothing else, so anything that must survive
# one has to live here.
#
# Two things have to be true for this to be safe rather than merely
# clever, and both are inherited from the wireguard arrangement:
#
#   1. The filesystem must be created exactly once, and never again over
#      live data. Hence: only format when the label is absent, and refuse
#      to guess when the candidate is ambiguous.
#   2. If the disk is absent or fails to mount, nothing may run against
#      the root disk instead. The generator unit's unitConfig
#      .RequiresMountsFor is what prevents that; see default.nix.
{ config, lib, pkgs, ... }:

let
  # The volume's filesystem label and its mount point. The label is
  # what the format unit looks for and what the mount unit names, so
  # the two cannot drift apart; the mount point is the directory the
  # runner's state, secrets and generated config all live under.
  #
  # NOT the volume's name. Incus calls that `forgejo-runner-data`
  # (incus.nix) and may call it whatever it likes; an ext4 label is
  # capped at 16 bytes, and mkfs.ext4 truncates anything longer with
  # only a warning:
  #
  #   Warning: label too long; will be truncated to 'forgejo-runner-d'
  #
  # That is how the first deploy of this VM ended with the runner down
  # and nothing wrong in any log: the mount's `what` named a label mkfs
  # had silently shortened, so systemd never created the mount unit at
  # all, the generator unit's RequiresMountsFor correctly refused to
  # run, and the daemon died on `result 'dependency'`. The label and
  # the volume name being the same 19-character string is what made
  # that look structural rather than a one-character fix.
  #
  # Nor is a device NAME usable here. Growing the root disk (see
  # `rootDiskSize` in incus.nix) renumbered the guest's virtio disks:
  # the root filesystem went from sda2 to sdb2 and this volume took
  # over sda, with no other change to the instance. A label survives
  # that; `sdb` would not have.
  label = "forgejo-runner";
  dataDir = "/var/lib/forgejo-runner";
in
{
  # ext4 caps a volume label at 16 bytes. Asserted here rather than left
  # for mkfs.ext4 to decide silently: a build-time failure is the only
  # place this costs nothing. Truncation instead produces a VM that
  # boots, mounts nothing, and reports success.
  assertions = [
    {
      assertion = lib.stringLength label <= 16;
      message = "ext4 volume labels are capped at 16 bytes; '${label}' is ${toString (lib.stringLength label)} and mkfs.ext4 will truncate it";
    }
  ];
  # After the first boot this is a no-op that checks for the label and
  # exits.
  #
  # The ordering and the wantedBy are set further down, next to the
  # mount they relate to, because the two have to be read together to
  # make sense.
  systemd.services.forgejo-runner-data-format = {
    description = "Format the forgejo-runner data disk if it does not have the expected label";

    # DefaultDependencies=no drops the implicit After=basic.target that
    # every service gets, because basic.target is After=sysinit.target
    # which is After=local-fs.target -- i.e. the default is precisely
    # the cycle this arrangement exists to avoid. Nothing else is
    # needed ahead of local-fs.target; the ordering that matters is the
    # explicit Before= below.
    unitConfig.DefaultDependencies = "no";

    before = [
      "local-fs.target"
      "shutdown.target"
    ];

    # Do not leave a half-formatted filesystem behind if the VM is
    # powered off mid-mkfs. With DefaultDependencies=no the usual
    # Conflicts=shutdown.target is not implied, so it is stated here.
    conflicts = [ "shutdown.target" ];

    # Wanted, not required, by local-fs.target: a VM with no data disk
    # attached must still boot -- you need to be able to log in and fix
    # it. The cost is that the mount is not strictly required for boot;
    # the generator unit's requiresMountsFor is what keeps the runner
    # off the root disk.
    wantedBy = [ "local-fs.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -eu

      # Absolute store paths, not bare names. A NixOS oneshot unit gets
      # a PATH of coreutils/findutils/grep/sed/systemd and nothing else
      # -- util-linux is not in it -- so a bare `findmnt` or `lsblk`
      # fails with "command not found" the first time this runs, which
      # is on a fresh disk, i.e. the first boot. That is exactly when
      # nobody is watching the log. `logger` is util-linux too, and it
      # was missed here once on the wireguard VM: with `set -eu` a
      # missing `logger` is not a lost log line, it is exit 127 and no
      # disk formatted.
      findmnt=${pkgs.util-linux}/bin/findmnt
      lsblk=${pkgs.util-linux}/bin/lsblk
      logger=${pkgs.util-linux}/bin/logger
      mkfs_ext4=${pkgs.e2fsprogs}/sbin/mkfs.ext4

      by_label=/dev/disk/by-label/${label}
      if [ -e "$by_label" ]; then
        "$logger" -t forgejo-runner-data-format "data disk already carries label ${label}, leaving it alone"
        exit 0
      fi

      # mkfs.ext4 truncates an over-long label with a warning and exits 0,
      # so a successful run is not evidence that the label took. Check it,
      # because "formatted, and the mount's `what` will therefore never
      # resolve" is otherwise indistinguishable from success in every log
      # on the box.
      #
      # The wait is `udevadm settle` (absolute path, for the reason above)
      # AND a sleep, because the settle alone is not a retry: when nothing
      # is queued it returns immediately, so ten back-to-back settles finish
      # in microseconds and give up long before udev has created the symlink.
      # `sleep` is coreutils, which this unit's PATH does have.
      verify_label() {
        local what=$1
        udadm_settle=${pkgs.systemd}/bin/udevadm
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          [ -e "$by_label" ] && return 0
          "$udadm_settle" --timeout=2 2>/dev/null || true
          sleep 1
        done
        "$logger" -t forgejo-runner-data-format -p user.err \
          "''${what}, but /dev/disk/by-label/${label} does not exist afterwards"
        "$logger" -t forgejo-runner-data-format -p user.err \
          "  the filesystem label is probably not the string asked for -- check with: lsblk -o NAME,LABEL"
        "$logger" -t forgejo-runner-data-format -p user.err \
          "  leaving ${dataDir} unmounted so the runner stays down"
        exit 1
      }

      # Identify the root disk and never touch it. Without this the
      # loop below could pick /dev/vda and format the filesystem this
      # script is running on.
      root_src=$("$findmnt" -n -o SOURCE /)
      root_disk=""
      if [ -b "$root_src" ]; then
        root_disk=$("$lsblk" -ndo PKNAME "$root_src" 2>/dev/null || true)
      fi

      candidates=""
      for d in /dev/disk/by-id/virtio-* /dev/vd? /dev/nvme?n? /dev/sd?; do
        [ -b "$d" ] || continue
        # Resolve to the kernel's own name before anything else. The
        # glob above deliberately lists both a by-id symlink and the
        # /dev node, so the same disk arrives twice -- and then $# is
        # 2, the case below takes the "refusing to guess" branch, and
        # the disk this script exists to format is the one it refuses.
        # That is a fresh-disk bug, so it would bite on exactly the
        # first boot and never again.
        r=$(readlink -f "$d")
        [ -n "$root_disk" ] && [ "$r" = "/dev/$root_disk" ] && continue
        case " $candidates " in
          *" $r "*) continue ;;
        esac
        # A blank disk has no children. Anything reporting a partition,
        # LVM or crypt device is in use and is not ours to format.
        if "$lsblk" -nrpo TYPE "$r" 2>/dev/null | grep -qvE '^disk$'; then
          continue
        fi
        candidates="$candidates $r"
      done

      # shellcheck disable=SC2086
      set -- $candidates
      case $# in
        0)
          "$logger" -t forgejo-runner-data-format -p user.err \
            "no blank data disk found; leaving ${dataDir} unmounted so the runner stays down"
          exit 1
          ;;
        1)
          "$logger" -t forgejo-runner-data-format "formatting $1 as ext4 with label ${label}"
          "$mkfs_ext4" -q -L "${label}" "$1"
          verify_label "formatted $1"
          ;;
        *)
          "$logger" -t forgejo-runner-data-format -p user.err \
            "more than one blank disk ($*) -- refusing to guess"
          exit 1
          ;;
      esac
    '';
  };

  systemd.mounts = [
    {
      what = "/dev/disk/by-label/${label}";
      where = dataDir;

      # The option is `type`, not `fsType`. `fsType` is what
      # fileSystems.* uses, and mixing the two up fails with
      # "option ...fsType does not exist".
      type = "ext4";

      # nofail, because a VM with no data disk attached should still
      # boot -- you need to be able to log in and fix it. The cost is
      # that the mount is not strictly required for boot; the generator
      # unit's requiresMountsFor is what actually keeps the runner off
      # the root disk.
      #
      # One comma-separated string, not a list. systemd.mounts.options
      # is typed "strings concatenated with ,", so a list of them fails
      # with "not of type `strings concatenated with \",\"'". Other
      # systemd options take lists; this one does not.
      #
      # No x-systemd.* options here, and that is deliberate. Both of
      # the ones the wireguard VM used to carry -- x-systemd.requires=
      # and x-systemd.device-timeout= -- are implemented by
      # systemd-fstab-generator, not by the mount unit itself
      # (src/fstab-generator/fstab-generator.c; systemd.mount(5) scopes
      # both to "an entry from /etc/fstab"). NixOS's systemd.mounts does
      # not write an fstab entry -- it writes the .mount unit directly --
      # so the generator never runs and both options are inert. They
      # survive only as literal text in the unit's Options=, where
      # mount(8) rejects them outright.
      options = "nofail,noatime";

      # The dependency itself, on the mount rather than on the format
      # unit. Putting it here rather than as a systemd.services entry
      # naming this same unit is not a style choice: systemd.units
      # merges services first and mounts last (systemd.nix), so a
      # services entry for this .mount would be silently overwritten by
      # the mount generated here.
      requires = [ "forgejo-runner-data-format.service" ];
      after = [ "forgejo-runner-data-format.service" ];
    }
  ];

  # The mount -> format dependency, expressed so that systemd actually
  # honours it. See the note on the mount options above for why the
  # fstab spelling of this did nothing.
  #
  # It goes on the *format* unit rather than on the mount, and that is
  # forced: systemd.units merges services first and mounts last
  # (systemd.nix, the `systemd.units = ...` definition), so a
  # systemd.services entry naming this same .mount unit would be
  # silently overwritten by the mount generated above. Ordering the
  # format unit before the mount gets the same guarantee without
  # fighting that merge.
  #
  # local-fs.target is the real ordering constraint, not the mount. A
  # mount unit is pulled into local-fs.target, and the format has to
  # happen before the mount the label is for. The format unit is
  # WantedBy= local-fs.target and Before= it, and the mount unit
  # Requires= and is After= the format unit, so the relationship does
  # not depend on local-fs.target's internals -- and is not stated a
  # second time on the format unit, which would be a cycle.
}
