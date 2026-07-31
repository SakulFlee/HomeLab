{ config, pkgs, lib, ... }:

let
  cfg = config.services.homelab-restic;
  repo = "/mnt/nas/HomeLab-Backups";
in {
  options.services.homelab-restic = {
    enable = lib.mkEnableOption "Restic backup to NAS for homelab services";

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [];
      description = "Paths to include in backup.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/restic-password";
      description = "Path to restic repository password file.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.restic-password = {};

    environment.systemPackages = with pkgs; [ restic ];

    systemd.services.homelab-restic = {
      description = "Restic backup for homelab services";
      after = [ "network.target" "remote-fs.target" ];
      wants = [ "remote-fs.target" ];
      path = with pkgs; [ restic ];
      serviceConfig = {
        Type = "oneshot";
      };
      environment.HOME = "/root";
      script = ''
        restic backup \
          -r "${repo}" \
          --password-file "${cfg.passwordFile}" \
          ${builtins.concatStringsSep " " cfg.paths} \
          --tag $(cat /proc/sys/kernel/hostname) \
          --exclude-caches

        restic forget \
          -r "${repo}" \
          --password-file "${cfg.passwordFile}" \
          --keep-hourly 24 \
          --keep-daily 7 \
          --keep-weekly 4 \
          --keep-monthly 3 \
          --prune
      '';
    };

    systemd.timers.homelab-restic = {
      description = "Hourly restic backup timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
