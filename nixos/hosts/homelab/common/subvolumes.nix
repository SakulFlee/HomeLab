{ config, lib, pkgs, ... }: {
  # One-shot: create the k8s and backups btrfs subvolumes if they don't exist.
  # Mounts the top-level subvolume (id 5) to create siblings of home/nix, then
  # unmounts. Reproducible so this also works when HomeLab is reinstalled.
  systemd.services.ensure-btrfs-subvolumes = {
    description = "Ensure btrfs subvolumes exist";
    wantedBy = [ "local-fs.target" ];
    before = [ "var-lib-rancher.mount" "var-lib-backups.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      DEV=/dev/disk/by-uuid/f947dbe8-fde3-4002-92bf-fee906abab73
      MNT=/mnt/btrfs-top
      mkdir -p "$MNT"
      mount -t btrfs -o subvol=/ "$DEV" "$MNT"

      for sub in k8s backups; do
        if ! btrfs subvolume list "$MNT" | grep -q " $sub$"; then
          btrfs subvolume create "$MNT/$sub"
        fi
      done

      umount "$MNT"
    '';
  };

  fileSystems."/var/lib/rancher" = {
    device = "/dev/disk/by-uuid/f947dbe8-fde3-4002-92bf-fee906abab73";
    fsType = "btrfs";
    options = [ "subvol=k8s" ];
  };

  fileSystems."/var/lib/backups" = {
    device = "/dev/disk/by-uuid/f947dbe8-fde3-4002-92bf-fee906abab73";
    fsType = "btrfs";
    options = [ "subvol=backups" ];
  };
}
