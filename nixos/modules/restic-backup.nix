{ config, pkgs, lib, ... }:

let
  cfg = config.services.restic-backup;
  repo = cfg.repository;
  onNas = lib.hasPrefix "/mnt/nas" repo;
in {
  options.services.restic-backup = {
    enable = lib.mkEnableOption "Restic backup to NAS";

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [];
      description = "Paths to include in backup.";
    };

    repository = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/nas/HomeLab-Backups";
      description = "Restic repository path.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/restic-password";
      description = "Path to restic repository password file.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."restic-password" = {
      sopsFile = ../secrets/restic.sops.yaml;
    };

    environment.systemPackages = with pkgs; [ restic ];

    fileSystems = lib.mkIf onNas {
      "/mnt/nas" = {
        device = "192.168.178.250:/mnt/atticus/Backups";
        fsType = "nfs";
        options = [ "noatime" "nodiratime" "soft" "noexec" ];
      };
    };

    systemd.services.restic-backup = {
      description = "Daily restic backup to NAS";
      after = [ "network.target" "remote-fs.target" ];
      wants = [ "remote-fs.target" ];
      path = with pkgs; [ restic ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        restic -r "${repo}" snapshots 2>/dev/null || \
          restic -r "${repo}" init

        restic -r "${repo}" backup \
          ${builtins.concatStringsSep " " cfg.paths} \
          --tag ${config.networking.hostName} \
          --exclude-caches \
          --one-file-system

        restic -r "${repo}" forget \
          --keep-daily 7 --keep-weekly 4 --keep-monthly 3 \
          --prune
      '';
    };

    systemd.timers.restic-backup = {
      description = "Daily restic backup timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
