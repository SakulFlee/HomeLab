{ config, pkgs, lib, ... }:

let
  dev = "/dev/disk/by-uuid/f947dbe8-fde3-4002-92bf-fee906abab73";
  snapRoot = "/var/lib/backups/snapshots";
  # btrfs subvol path of snapshots relative to the top-level subvolume (id 5).
  snapSubvol = "backups/snapshots";
  repo = "/var/lib/backups/repo";
  mountPoint = "/mnt/k8s-snapshot";
  # Volatile (reclaimPolicy: Delete) PVCs live under /storage/volatile and are
  # excluded from backups; only persistent data is retained.
  volatilePath = "storage/volatile";
in {
  sops.secrets.restic-password = {};

  environment.systemPackages = with pkgs; [ restic btrfs-progs ];

  systemd.services.homelab-backup = {
    description = "Snapshot k8s subvolume and back it up with restic";
    after = [ "network.target" "remote-fs.target" "var-lib-backups.mount" ];
    wants = [ "remote-fs.target" ];
    path = with pkgs; [ restic btrfs-progs ];
    serviceConfig = {
      Type = "oneshot";
    };
    environment.HOME = "/root";
    script = ''
      set -euo pipefail

      mkdir -p "${snapRoot}"
      snap="${snapRoot}/k8s-$(date +%F-%H%M%S)"
      btrfs subvolume snapshot -r /var/lib/rancher "$snap"

      cleanup() {
        mountpoint -q "${mountPoint}" && umount "${mountPoint}" || true
        btrfs subvolume delete "$snap" >/dev/null 2>&1 || true
      }
      trap cleanup EXIT

      mkdir -p "${mountPoint}"
      mount -t btrfs -o "subvol=${snapSubvol}/$(basename "$snap"),ro" "${dev}" "${mountPoint}"

      if ! restic cat config -r "${repo}" --password-file /run/secrets/restic-password >/dev/null 2>&1; then
        restic init -r "${repo}" --password-file /run/secrets/restic-password >/dev/null 2>&1
      fi

      restic backup \
        -r "${repo}" \
        --password-file /run/secrets/restic-password \
        "${mountPoint}" \
        --exclude "${volatilePath}" \
        --tag k8s \
        --exclude-caches

      restic forget \
        -r "${repo}" \
        --password-file /run/secrets/restic-password \
        --keep-hourly 24 \
        --keep-daily 7 \
        --keep-monthly 3 \
        --prune
    '';
  };

  systemd.timers.homelab-backup = {
    description = "Hourly btrfs snapshot + restic backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}