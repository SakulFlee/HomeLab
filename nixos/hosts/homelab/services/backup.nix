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

  # Which media shares live on the local tree, and therefore have to be in the
  # backup set. Plain data, shared with mount-nas.nix, mount-media.nix and each
  # media instance's incus.nix.
  media = import ../../../modules/media-shares.nix;

  # Not lib.getExe': that wants a derivation, and writeShellApplication is a
  # function. Building it in a let and interpolating the result is the ordinary
  # way to get a script's path, and keeps the script text out of the unit file
  # where `systemctl cat` would print it in full.
  script = pkgs.writeShellApplication {
    name = "restic-backup";
    runtimeInputs = [
      pkgs.restic
      pkgs.coreutils
      # flock is util-linux, not coreutils. Its absence was not a crash: the
      # call sits inside an `if !` condition, which set -e exempts, so
      # "command not found" was indistinguishable from "lock held" and the
      # script exited 0 having done nothing at all. systemd reported success on
      # two consecutive runs. See the preflight below.
      pkgs.util-linux
    ];
    text = ''
      pw=${config.sops.secrets.restic_password.path}
      repo=${lib.escapeShellArg cfg.repository}
      tag=${lib.escapeShellArg cfg.tag}

      # ------------------------------------------------------------------------
      # Preflight. Every tool this script needs, checked before anything runs.
      # ------------------------------------------------------------------------
      # Because the lock test below is an `if !` condition, set -e does not
      # apply to it, and a *missing* flock is silently read as a *held* lock. That
      # is the worst possible failure for a backup: the unit goes green, the
      # timer keeps firing, and nothing is ever backed up. It happened, twice,
      # before this check existed:
      #
      #   restic-backup[...]: .../bin/restic-backup: line 20: flock: command not found
      #   restic-backup[...]: another restic-backup run holds the lock; skipping this tick
      #   systemd[1]: restic-backup.service: Deactivated successfully.
      #
      # So the tools are verified up front and their absence is fatal. A loud
      # failure every hour is worth far more than a green unit that backs up
      # nothing.
      missing=
      for tool in restic flock; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
      done
      if [ -n "$missing" ]; then
        echo "FATAL: not on PATH:$missing -- refusing to report success without doing the backup" >&2
        exit 1
      fi

      # Two schedules write this repository, so the lock is contended by design
      # and --retry-lock is what makes that a wait rather than an error. flock
      # keeps a second *host* run from starting while this one is still going,
      # which systemd's timer alone does not guarantee.
      #
      # flock is exited on purpose: if the previous run is still going, the next
      # tick should be a no-op, not a second concurrent backup of the same paths.
      # That skip is only ever reached now that flock is known to exist.
      exec 9>/run/restic-backup.lock
      if ! flock -n 9; then
        echo "another restic-backup run holds the lock; skipping this tick"
        exit 0
      fi

      # --exclude-caches, as the DaemonSet does: Incus writes cache metadata into
      # its pool directories that changes on unrelated operations and would churn
      # every snapshot for no benefit.
      #
      # Its exit status is captured rather than left to abort the script, because
      # of what restic means by the three that matter:
      #
      #   0  everything read
      #   1  a real error -- the snapshot may be missing, or the repo unusable
      #   3  the snapshot WAS saved, but some source files could not be read
      #
      # 3 is the one that bites, and it bit for 17 hours. On 2026-10-06 the
      # repository index had just been rebuilt, so restic had to re-upload a
      # dozen repo-archive files it could not find in the index. It stored them,
      # saved the snapshot, printed "Warning: at least one source file could not
      # be read" and exited 3 -- and because this script runs under
      # writeShellApplication's `set -o errexit`, that exit killed it before
      # `restic forget` below. The unit went red and retention did not run: the
      # same outage as the one before it (prune failing on "packs from index
      # missing in repo") wearing a different error, and one that would recur
      # indefinitely over any file restic cannot read.
      #
      # So a backup that saved its snapshot is good enough to prune against. Only
      # a hard error skips the prune, because pruning on top of a genuinely
      # broken backup is the one case where not proceeding is the safer choice.
      backup_status=0
      restic backup \
        --retry-lock=10m \
        --password-file "$pw" \
        -r "$repo" \
        --tag "$tag" \
        --exclude-caches \
        ${lib.escapeShellArgs cfg.paths} || backup_status=$?

      if [[ $backup_status -ne 0 && $backup_status -ne 3 ]]; then
        echo "FATAL: restic backup exited $backup_status -- not pruning against a backup that may not have saved" >&2
        exit "$backup_status"
      fi
      if [[ $backup_status -eq 3 ]]; then
        echo "restic backup saved its snapshot but could not read some source files (exit 3); pruning anyway" >&2
      fi

      # Pruning is scoped twice over, and both parts matter. --tag limits it to
      # our own snapshots so the k3s tier's history is untouched; --group-by tags
      # stops restic grouping ours together with anything else sharing this host
      # and paths, which would let a policy meant for one schedule delete the
      # other's snapshots.
      #
      # --retry-lock here too, not just on the backup above. The DaemonSet runs
      # its own forget/prune against this repository hourly, and without it a
      # collision is an immediate failure rather than a wait -- which is how a
      # routine overlap turns into a red unit every time the two schedules drift
      # into the same minute.
      #
      # Neither side may prune while the other holds the lock. That is the whole
      # reason the DaemonSet stopped passing `unlock --remove-all`: it deleted
      # the lock this wait depends on, let two prunes overlap, and left the
      # repository with an index referencing 16 pack files that no longer existed
      # ("Fatal: packs from index missing in repo"), after which every run here
      # failed at prune. Repaired with `restic repair index`. The other half of
      # that story is in apps/storage-class/restic-daemonset.yaml, which is also
      # where the fix has to be kept in step if either side changes.
      restic forget \
        --retry-lock=10m \
        --password-file "$pw" \
        -r "$repo" \
        --tag "$tag" \
        --group-by tags \
        --keep-hourly ${toString cfg.keepHourly} \
        --keep-daily ${toString cfg.keepDaily} \
        --keep-monthly ${toString cfg.keepMonthly} \
        --prune

      # Retention has now run, which was the whole point of the branch above.
      # Still report the incomplete backup rather than exiting 0: an unreadable
      # source file is a real problem someone has to look at, and swallowing it
      # to turn the unit green is how you get a green-but-not-backing-up unit --
      # the exact failure this script's preflight exists to prevent.
      if [[ $backup_status -ne 0 ]]; then
        exit "$backup_status"
      fi
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
        not a second repository: one repo means one password and one retention
        policy to reason about.

        It used to be replicated off the box by the k3s Syncthing, which mounted
        /var/lib/backups. That Syncthing has been retired and the Incus one in
        hosts/syncthing does NOT mount this directory, so nothing copies the
        repository off-box any more. That is a deliberate decision recorded here
        rather than left as a comment that reads as if it were still true.
      '';
    };

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Derived, not written out. The list is the pool plus whatever media
      # shares resolve to the local tree in modules/media-shares.nix, minus
      # qBittorrent -- and that is derived so it stays correct the moment a
      # share is moved rather than needing this file to be remembered too.
      #
      # The exclusion is the one judgement call in it: downloads are
      # re-downloadable and a 555G library of torrents is not worth an hourly
      # restic scan, so qBittorrent is left out wherever it lives. Everything
      # else in the library is recoverable from nowhere else, so it is included
      # wherever it is.
      #
      # With all five shares resolving to /mnt/nas today, this is just the pool
      # -- the same single path as before, since nothing is stored locally yet.
      default = [
        "/var/lib/incus/storage-pools/persistent"
      ] ++ map (share: "${media.localMount}/${share}") media.localLibraryShares;
      description = ''
        What to back up. The single remaining pool: `backup` was merged into
        `persistent` (same btrfs driver, same filesystem, no quota, nothing
        ever enforced a difference), so there is one path and it is this one.
        Removed from the list at the same commit that dropped the pool from
        the preseed, because restic fails on a path that no longer exists --
        and the pool itself is deleted by hand afterwards, which is the one
        ordering preseed's never-removes rule forces.

        Local media shares are appended automatically. The NAS shares are
        deliberately NOT in this list: they are already the NAS's own data, and
        copying 2.1T of it hourly into a restic repo on the same host would be
        a second copy that lives in the same house as the first. Once a share
        is moved onto /mnt/media it stops being the NAS's problem and starts
        being this host's, which is exactly when it appears here -- without
        anyone having to edit this file.

        Keeping a copy of PGDATA does no harm. What is not permitted is
        RESTORING from one: a pg_dump is the authoritative artefact and a
        file-level copy of a live data directory is not a substitute for one.
        Those are two separate claims, and an old version of the pool comment
        used the first to argue for the second. Having the copy means a
        forensic artefact survives an incident; it does not mean anyone should
        trust it as a database.
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

    # The cache directory above, created once by the unit's own ExecStartPre.
    # DirectoryPermisionsModified is deliberately absent: systemd would then
    # relax the mode to 0755 on an existing directory, and a restic cache is
    # only useful to root here anyway.
    systemd.tmpfiles.rules = [
      "d /var/cache/restic 0700 root root -"
    ];

    systemd.services.restic-backup = {
      description = "Back up the Incus storage pools to the shared restic repository";
      documentation = [ "man:restic(1)" ];

      # Nothing to do until the repository exists. It is created by
      # `restic init`, which the DaemonSet performs on its first run; before
      # that, failing once an hour with "repository does not exist" in the
      # journal is more informative than masking the condition.
      unitConfig.ConditionPathExists = cfg.repository;

      # restic keeps a local index cache and looks for it under
      # $XDG_CACHE_HOME or $HOME. A systemd unit has neither, so the first run
      # logged
      #
      #   unable to open cache: neither $XDG_CACHE_HOME nor $HOME are defined
      #
      # and every run since re-reads the whole repository index rather than
      # consulting it. With 31 snapshots and 1M files that is real work to repeat
      # hourly, and it is a warning easy to stop reading once it is expected.
      environment = {
        HOME = "/root";
        XDG_CACHE_HOME = "/var/cache/restic";
      };

      serviceConfig = {
        Type = "oneshot";
        # ${script}/bin/restic-backup, NOT ${script}.
        #
        # writeShellApplication returns a derivation whose output is a
        # *directory* containing bin/<name>, so interpolating the derivation
        # directly yields a path with no /bin/ on the end and systemd fails with
        #
        #   Failed at step EXEC spawning /nix/store/…-restic-backup:
        #   Is a directory
        #
        # lib.getExe' is the accessor for exactly this: it takes a derivation and
        # the name inside it. It cannot be used on pkgs.writeShellApplication
        # itself, which is a function rather than a derivation -- hence the let
        # binding above.
        #
        # Restic reads the password from the sops-rendered file. Not an
        # EnvironmentFile: the value would then be in the unit's environment,
        # visible in /proc/<pid>/environ to anything that can read it.
        ExecStart = lib.getExe' script "restic-backup";
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