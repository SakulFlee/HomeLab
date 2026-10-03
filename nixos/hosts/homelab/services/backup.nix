# Host-side restic for the Incus storage pools.
#
# This file is the one the homelab-restic DaemonSet's header has been referring
# to all along -- "matches the NixOS unit's --password-file path" and
# "see nixos/hosts/homelab/common/backup.nix" -- which did not exist. So the
# comment pointed at a plan rather than at code, and nothing on this host backed
# anything up: there was no restic binary, service or timer here at all.
#
# The only restic in this homelab was the DaemonSet, and it backs up exactly one
# path:
#
#   BACKUP_TIER="/var/lib/rancher/k3s/storage/backup"
#
# the k3s PVC tier. It does not know Incus exists. So the Incus pools -- which
# hold caddy-data, and now the whole of Forgejo -- were on no backup schedule
# whatsoever, while the pool comment in services/incus.nix claimed `backup` was
# "restic'd. Anything whose loss you would actually notice." Both pools are in
# fact identical btrfs subvolumes on the same filesystem with no quota; the split
# between them was a comment, and the comment was wrong about the backup too.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.restic-backup;

  # Not lib.getExe': that wants a derivation, and writeShellApplication is a
  # function. Building it in a let and interpolating the result is the ordinary
  # way to get a script's path, and keeps the script text out of the unit file
  # where `systemctl cat` would print it in full.
  script = pkgs.writeShellApplication {
    name = "restic-backup";
    runtimeInputs = [
      pkgs.restic
      pkgs.coreutils
    ];
    text = ''
      pw=${config.sops.secrets.restic_password.path}
      repo=${lib.escapeShellArg cfg.repository}
      tag=${lib.escapeShellArg cfg.tag}

      # Two schedules write this repository, so the lock is contended by design
      # and --retry-lock is what makes that a wait rather than an error. flock
      # keeps a second *host* run from starting while this one is still going,
      # which systemd's timer alone does not guarantee.
      #
      # flock is exited on purpose: if the previous run is still going, the next
      # tick should be a no-op, not a second concurrent backup of the same paths.
      exec 9>/run/restic-backup.lock
      if ! flock -n 9; then
        echo "another restic-backup run holds the lock; skipping this tick"
        exit 0
      fi

      # --exclude-caches, as the DaemonSet does: Incus writes cache metadata into
      # its pool directories that changes on unrelated operations and would churn
      # every snapshot for no benefit.
      restic backup \
        --retry-lock=10m \
        --password-file "$pw" \
        -r "$repo" \
        --tag "$tag" \
        --exclude-caches \
        ${lib.escapeShellArgs cfg.paths}

      # Pruning is scoped twice over, and both parts matter. --tag limits it to
      # our own snapshots so the k3s tier's history is untouched; --group-by tags
      # stops restic grouping ours together with anything else sharing this host
      # and paths, which would let a policy meant for one schedule delete the
      # other's snapshots.
      restic forget \
        --password-file "$pw" \
        -r "$repo" \
        --tag "$tag" \
        --group-by tags \
        --keep-hourly ${toString cfg.keepHourly} \
        --keep-daily ${toString cfg.keepDaily} \
        --keep-monthly ${toString cfg.keepMonthly} \
        --prune
    '';
  };
in
{
  options.services.restic-backup = {
    enable = lib.mkEnableOption "hourly restic backup of the Incus storage pools";

    repository = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/backups/repo";
      description = ''
        The restic repository. The SAME one the homelab-restic DaemonSet writes,
        not a second repository: one repo means one password, one retention
        policy to reason about, and Syncthing already replicates this directory
        off the box, so off-box replication comes along for free rather than
        needing a second target configured.
      '';
    };

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/var/lib/incus/storage-pools/backup"
        "/var/lib/incus/storage-pools/persistent"
      ];
      description = ''
        What to back up. Both pools, because "persistent" is a name and not a
        mechanism: it is the same btrfs driver on the same filesystem as
        "backup", with no quota and nothing enforcing a difference.

        Both are included deliberately, and the reasoning is worth stating
        because an earlier version of the pool comment argued the opposite.
        Keeping a copy of PGDATA does no harm. What is not permitted is
        RESTORING from one: a pg_dump is the authoritative artefact and a
        file-level copy of a live data directory is not a substitute for one.
        Those are two separate claims, and the old text used the first to argue
        for the second. Having the copy means a forensic artefact survives an
        incident; it does not mean anyone should trust it as a database.
      '';
    };

    tag = lib.mkOption {
      type = lib.types.str;
      default = "incus";
      description = ''
        Snapshot tag. Distinct from the DaemonSet's `k8s` so that pruning here
        cannot reach the k3s tier's snapshots, and so the two schedules can be
        reasoned about separately.
      '';
    };

    # Same retention as the DaemonSet, so the repository as a whole has one
    # answer to "how much history do we keep" rather than two.
    keepHourly = lib.mkOption {
      type = lib.types.int;
      default = 24;
    };
    keepDaily = lib.mkOption {
      type = lib.types.int;
      default = 7;
    };
    keepMonthly = lib.mkOption {
      type = lib.types.int;
      default = 3;
    };

    # Off the hour on purpose. The DaemonSet sleeps 3600s plus 0-5min jitter
    # after each run, so it fires somewhere in the first few minutes of an hour.
    # Landing at :37 puts this run a clear half-hour away from it, which is what
    # keeps the two from contending for the repository lock every time.
    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* *:37:00";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.restic_password = { };

    environment.systemPackages = [ pkgs.restic ];

    systemd.services.restic-backup = {
      description = "Back up the Incus storage pools to the shared restic repository";
      documentation = [ "man:restic(1)" ];

      # Nothing to do until the repository exists. It is created by
      # `restic init`, which the DaemonSet performs on its first run; before
      # that, failing once an hour with "repository does not exist" in the
      # journal is more informative than masking the condition.
      unitConfig.ConditionPathExists = cfg.repository;

      serviceConfig = {
        Type = "oneshot";
        # Restic reads the password from the sops-rendered file. Not an
        # EnvironmentFile: the value would then be in the unit's environment,
        # visible in /proc/<pid>/environ to anything that can read it.
        ExecStart = "${script}";
      };
    };

    systemd.timers.restic-backup = {
      description = "Hourly restic backup of the Incus storage pools";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        # A missed window (host off, timer not running) should still result in a
        # backup once it is back, rather than being silently skipped.
        Persistent = true;
        # Without this, systemd considers the timer "active" purely because the
        # timer unit is up, and a machine that was off for two days would come
        # back claiming it had never missed one.
        AccuracySec = "1m";
        RandomizedDelaySec = "5m";
      };
    };
  };
}