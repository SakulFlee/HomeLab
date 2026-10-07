# The data volume for the fluxer VM.
#
# Fluxer runs Docker Compose inside a VM. Docker stores its data under
# /var/lib/docker. The block volume "fluxer-data" is attached to the VM
# and mounted as ext4 on /var/lib/docker by the guest.
{ config, lib, pkgs, ... }:
let
  label = "fluxer-data";
  mountPoint = "/var/lib/docker";
in
{
  systemd.services.fluxer-data-format = {
    description = "Format the Fluxer data disk if it does not have the expected label";

    unitConfig.DefaultDependencies = "no";

    before = [
      "local-fs.target"
      "shutdown.target"
    ];

    conflicts = [ "shutdown.target" ];

    wantedBy = [ "local-fs.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -eu

      findmnt=${pkgs.util-linux}/bin/findmnt
      lsblk=${pkgs.util-linux}/bin/lsblk
      logger=${pkgs.util-linux}/bin/logger
      mkfs_ext4=${pkgs.e2fsprogs}/sbin/mkfs.ext4

      by_label=/dev/disk/by-label/${label}
      if [ -e "$by_label" ]; then
        "$logger" -t fluxer-data-format "data disk already carries label ${label}, leaving it alone"
        exit 0
      fi

      # Identify the root disk and never touch it.
      root_src=$("$findmnt" -n -o SOURCE /)
      root_disk=""
      if [ -b "$root_src" ]; then
        root_disk=$("$lsblk" -ndo PKNAME "$root_src" 2>/dev/null || true)
      fi

      candidates=""
      for d in /dev/disk/by-id/virtio-* /dev/vd? /dev/nvme?n? /dev/sd?; do
        [ -b "$d" ] || continue
        r=$(readlink -f "$d")
        [ -n "$root_disk" ] && [ "$r" = "/dev/$root_disk" ] && continue
        case " $candidates " in
          *" $r "*) continue ;;
        esac
        if "$lsblk" -nrpo TYPE "$r" 2>/dev/null | grep -qvE '^disk$'; then
          continue
        fi
        candidates="$candidates $r"
      done

      # shellcheck disable=SC2086
      set -- $candidates
      case $# in
        0)
          "$logger" -t fluxer-data-format -p user.err \
            "no blank data disk found; leaving ${mountPoint} unmounted so the service stays down"
          exit 1
          ;;
        1)
          "$logger" -t fluxer-data-format "formatting $1 as ext4 with label ${label}"
          "$mkfs_ext4" -q -L "${label}" "$1"
          ;;
        *)
          "$logger" -t fluxer-data-format -p user.err \
            "more than one blank disk ($*) -- refusing to guess"
          exit 1
          ;;
      esac
    '';
  };

  systemd.mounts = [
    {
      what = "/dev/disk/by-label/${label}";
      where = mountPoint;

      type = "ext4";

      options = "defaults,nofail";
    }
  ];

  # Ensure the mount exists before Docker starts (best effort).
  systemd.services.docker = {
    after = [ "fluxer-data-format.service" "var-lib-docker.mount" ];
    requires = [ "var-lib-docker.mount" ];
  };
}