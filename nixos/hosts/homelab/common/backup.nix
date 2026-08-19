{ config, pkgs, lib, ... }:

let
  repo = "/var/lib/backups/repo";
  # Only the "persistent + backup" tier is backed up (see storage-class).
  # Databases never live here directly: they run on local-path-persistent and
  # dump themselves (e.g. CNPG recurringBackups) into a local-path-backup PVC,
  # so consistency comes from app-level dumps, not filesystem snapshots.
  backupTier = "/var/lib/rancher/k3s/storage/backup";
in {
  sops.secrets.restic-password = {};

  environment.systemPackages = with pkgs; [ restic ];

  systemd.services.homelab-backup = {
    description = "Back up k8s persistent+backup storage tier with restic";
    after = [ "network.target" "remote-fs.target" ];
    wants = [ "remote-fs.target" ];
    path = with pkgs; [ restic ];
    serviceConfig = {
      Type = "oneshot";
    };
    environment.HOME = "/root";
    script = ''
      set -euo pipefail

      # The backup tier may legitimately be empty (no PVC provisioned on
      # local-path-backup yet). Skip cleanly rather than fail when absent.
      if [ ! -d "${backupTier}" ]; then
        echo "${backupTier} does not exist, skipping"
        exit 0
      fi

      restic backup \
        -r "${repo}" \
        --password-file /run/secrets/restic-password \
        "${backupTier}" \
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
    description = "Hourly restic backup of k8s storage";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}
