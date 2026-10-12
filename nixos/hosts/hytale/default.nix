# NixOS system for the Incus instance "hytale".
#
# A Hytale dedicated server run from a jar by a systemd unit. Replaces the k3s
# deployment in apps/hytale/ (a Helm chart wrapping a locally built container
# image), which was the same three things: a JVM, the official server jar plus
# Assets.zip, and a volume.
#
# ---------------------------------------------------------------------------
# Why not a nixpkgs module
# ---------------------------------------------------------------------------
#
# There is no Hytale module and there could not usefully be one. The server is a
# 110 MB closed-source jar plus a 3.4 GB Assets.zip, both fetched through an
# OAuth device-code flow that needs a human in front of a browser exactly once.
# A module would be a wrapper around "run this jar", which is what the unit at
# the bottom of this file already is.
#
# What this file does instead is what minecraft/default.nix does: pin the
# things that must not drift (the JVM, the heap, the backup policy), own the
# directories, and get out of the way.
#
# ---------------------------------------------------------------------------
# Why the backups are the server's own job
# ---------------------------------------------------------------------------
#
# The short version: Hytale flushes its resources to disk before it zips them,
# so it can back itself up while players are online. Minecraft cannot, which is
# why hosts/minecraft/default.nix stops the server around its tar.
#
# This was established by reading the bytecode of the running 0.6.8 jar rather
# than by assuming, because the difference decides the whole design:
#
#   Universe.runLockedBackup()
#     -> universeResources.flushAll()                  <- every resource to disk
#     -> BackupTask(Universe::getDirectory, dir)       <- its own ZipOutputStream
#
# and the scheduler that drives it:
#
#   SCHEDULED_EXECUTOR.scheduleWithFixedDelay(runner, _, freq, MINUTES)
#
# `flushAll()` before the zip is the whole point. There is no equivalent hook in
# Paper, and inventing one (RCON, a socket unit writing to stdin) would need a
# channel into the console that does not exist: the server has no RCON, no HTTP
# admin and no query API -- its only listening socket is 0.0.0.0:5520/udp.
#
# So this instance uses Hytale's scheduler for CREATION and a systemd timer for
# DELETION. Upstream retention is count-based and has no age-based option at
# all -- BackupConfig's codec has exactly five fields (Enabled,
# FrequencyMinutes, Directory, MaxCount, ArchiveMaxCount) and the CLI adds no
# sixth -- so the counts below are set out of the way and `hytale-backup.timer`
# prunes by age. See the backup timer at the bottom.
{ lib, pkgs, ... }:

let
  # -------------------------------------------------------------------------
  # JVM
  # -------------------------------------------------------------------------
  #
  # openjdk25, not the nixpkgs default. Hytale requires Java 25 and says so
  # ("Java 25 (required)"); running it on 21 is not a degraded mode, it is a
  # refusal to start. This pin is the same one minecraft arrived at for the same
  # reason, which is a coincidence worth noting -- two unrelated Java projects
  # landing on 25 in the same window.
  #
  # -Xmx4G is the k8s deployment's own JAVA_OPTIONS, kept verbatim. It has to fit
  # inside the 8GiB cgroup limit declared in ./incus.nix with room for metaspace,
  # the code cache and the mmapped asset map; that limit is one decision with
  # this one, not two.
  #
  # -XX:+UseStringDeduplication and -XX:+UseG1GC are also from the chart's
  # JAVA_OPTIONS. The duplicated `-server` in that string is dropped: it appears
  # twice there and the second one was always a no-op.
  javaOpts = lib.concatStringsSep " " [
    "-Xms512M"
    "-Xmx4G"
    "-XX:+UseG1GC"
    "-XX:+UseStringDeduplication"
  ];

  # -------------------------------------------------------------------------
  # Backup policy
  # -------------------------------------------------------------------------
  #
  # Daily, because the off-box copy is the durable layer and a game world does
  # not need sub-daily resolution. Hytale ships 30 minutes as the default, which
  # on a 178 MB universe is ~8 GB/day replicated to Dendra, forever -- a sendonly
  # folder never applies a remote deletion, so none of it is ever reclaimed.
  #
  # The two counts are set absurdly high on purpose. They are Hytale's retention
  # and this instance does not use them: `hytale-backup.timer` deletes by age
  # instead, which is a policy Hytale cannot express. Leaving these at their
  # defaults would mean two independent prunes racing over one directory, and
  # Hytale's would win the race by archiving rather than deleting -- moving
  # files into backups/archive/ that nothing then prunes.
  backupFrequencyMinutes = 1440;
  backupMaxCount = 100000;
  backupArchiveMaxCount = 100000;

  # How long an archive is kept. Seven days, which is the window in which
  # somebody notices that a world edit went wrong.
  #
  # This is deliberately an AGE and not a count, which is the entire reason the
  # server's own retention is disabled above: a count silently changes meaning
  # if the frequency is ever edited, and it does not survive a server that is
  # restarted more often than the interval (scheduleWithFixedDelay restarts its
  # timer on every boot, so a 24h frequency on a server that restarts daily
  # would produce one archive per boot and never reach a 24h cadence at all).
  backupKeepDays = 7;

  # -------------------------------------------------------------------------
  # The downloader
  # -------------------------------------------------------------------------
  #
  # There is no direct URL for the platform binary --
  # https://downloader.hytale.com/hytale-downloader-linux-amd64 is a 404 -- so
  # the archive is fetched and the one file we want is extracted from it. The
  # archive is a moving target by design: it carries the downloader's own
  # self-update mechanism, and pinning its hash would mean shipping a stale
  # downloader exactly when a new one is published. Integrity is checked
  # behaviourally instead, by running the extracted binary (-version) and
  # refusing to keep one that does not answer.
  downloaderUrl = "https://downloader.hytale.com/hytale-downloader.zip";
  downloaderBin = "hytale-downloader-linux-amd64";

  # The credentials file, on its own unsnapshotted volume. See the `secrets`
  # device in ./incus.nix for why this is not a renderedSecrets entry: the
  # downloader rewrites this file whenever its tokens refresh, and apply.sh runs
  # every fifteen minutes and would overwrite a refreshed token with a stale one.
  credentialsPath = "/var/lib/hytale-secrets/.hytale-downloader-credentials.json";
in
{
  networking.hostName = "hytale";

  # The host gates this instance; see incus.nix. Load-bearing rather than tidy:
  # the 5520/udp forward DNATs into this container, and a guest firewall would be
  # re-filtering traffic the host has already decided to admit.
  networking.firewall.enable = false;

  # The router, same as every other instance. Not optional: the downloader
  # resolves downloader.hytale.com and the Hytale update service through this.
  networking.nameservers = [ "192.168.178.1" ];

  # Not exposed: Incus reaches the instance via exec, and nothing forwards 22.
  services.openssh.enable = false;

  # curl for the downloader fetch, unzip because both the downloader archive and
  # the game payload it produces are zips, and jq so a config.json can be read
  # without guesswork. openjdk25 is here rather than referenced only by the unit
  # so that `incus exec hytale -- java -version` works while debugging.
  environment.systemPackages = with pkgs; [
    curl
    jq
    openjdk25
    unzip
  ];

  # -------------------------------------------------------------------------
  # The service account
  # -------------------------------------------------------------------------
  #
  # uid/gid 989, pinned, sitting between paperless (987) and minecraft (988) and
  # clear of qbittorrent (996). The number matters for one reason: the data load
  # from k3s has to land owned by a known uid, because the PVC's files are owned
  # by whatever uid the old image chose and copying them in preserves that.
  # Deciding the target number here makes the load a chown to 989 rather than a
  # question about what NixOS happened to allocate.
  #
  # No home directory: there is nothing to put in it, and `hytale-dirs` below
  # owns every directory the service writes to.
  users.users.hytale = {
    isSystemUser = true;
    group = "hytale";
    uid = 989;
    description = "Hytale dedicated server";
  };
  users.groups.hytale.gid = 989;

  # -------------------------------------------------------------------------
  # Owning the volumes
  # -------------------------------------------------------------------------
  #
  # Incus creates a disk device's mount point as 0711 root:root, which is right
  # for its purposes and useless to a service that has to write there. Same fix
  # forgejo, paperless and minecraft needed for the same reason, and `install -d`
  # rather than a tmpfiles rule for the reason paperless gives: tmpfiles runs
  # independently of (and in the general case before) the rest of activation,
  # whereas this is ordered explicitly ahead of everything that writes.
  #
  # install -d is idempotent and touches only the directory itself, never its
  # contents, so this does not walk a 178 MB universe.
  #
  # The .stfolder marker is created here as well as by the tmpfiles rule at the
  # bottom, for the reason minecraft gives: the rule covers ordering (tmpfiles
  # runs before the units that write into the volume, and it survives the volume
  # being mounted empty), and this covers the case where tmpfiles has already run
  # and something removed it. The Syncthing hub mounts hytale-backups READ-ONLY
  # and therefore can never create the marker itself -- without it the folder
  # sits "stopped" in the WebUI and nothing is ever replicated.
  systemd.services.hytale-dirs = {
    description = "Create and own the hytale volume mount points";
    wantedBy = [ "multi-user.target" ];
    before = [ "hytale-downloader.service" "hytale.service" ];
    after = [ "local-fs.target" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe' pkgs.coreutils "install"
        + " -d -m 0755 -o hytale -g hytale"
        + " /var/lib/hytale /var/lib/hytale/Server /var/lib/hytale/Server/backups /var/lib/hytale-secrets";
    };

    # The marker needs the directory to exist first, so it is a second ExecStart
    # rather than something folded into the install above: install -d on a path
    # whose parent does not exist yet would create the parents too, with the
    # wrong ownership.
    postStart = lib.getExe' pkgs.coreutils "mkdir" + " -p /var/lib/hytale/Server/backups/.stfolder";
  };

  # -------------------------------------------------------------------------
  # Fetching the downloader
  # -------------------------------------------------------------------------
  #
  # Separate from the download itself and wantedBy multi-user, so that the binary
  # is present after any recreate (the root disk is replaced wholesale) without
  # anyone having to think about it, and so that `hytale-download` can be re-run
  # for a patch without re-fetching anything.
  #
  # Idempotent in the way that matters: it skips entirely when the binary is
  # already there and answers -version. `-skip-update-check` is passed because
  # the downloader otherwise phones home on every invocation to announce a newer
  # version of itself, which is a network round trip on an interactive command
  # that is about to do a multi-gigabyte download anyway.
  #
  # `${downloaderUrl}` in braces, never `$downloaderUrl` bare, and this is the
  # same trap hosts/minecraft/default.nix documents for `paperApi`: Nix does not
  # interpolate a bare `$name` inside an indented ''…'' string, so it lands in
  # the script verbatim and arrives in the shell as an unset variable. With
  # `set -u` the unit dies on the *first* one, before a single byte is fetched:
  #
  #   hytale-downloader-start: line 13: downloaderUrl: unbound variable
  #
  # which names neither the URL nor the download. Every Nix value in every
  # script in this file is braced for that reason, including the ones that look
  # like shell variables. Cost one deploy to find out.
  systemd.services.hytale-downloader = {
    description = "Fetch the Hytale downloader";
    wantedBy = [ "multi-user.target" ];
    before = [ "hytale-download.service" "hytale.service" ];
    after = [ "hytale-dirs.service" "network-online.target" ];
    requires = [ "hytale-dirs.service" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.curl
      pkgs.unzip
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "hytale";
      Group = "hytale";
      WorkingDirectory = "/var/lib/hytale";
    };
    script = ''
      set -euo pipefail

      bin=/var/lib/hytale/${downloaderBin}

      if [ -x "$bin" ] && "$bin" -version >/dev/null 2>&1; then
        echo "hytale-downloader already present: $("$bin" -version)"
        exit 0
      fi

      echo "fetching ${downloaderUrl}"
      curl -fsSL --retry 3 --retry-delay 2 -o downloader.zip "${downloaderUrl}"

      # Extract only the file this platform needs. The archive also carries a
      # Windows .exe, and taking the first zip member blindly is how the wrong
      # one ends up in the volume on an architecture change.
      rm -f "$bin"
      unzip -o -j downloader.zip "${downloaderBin}" -d /var/lib/hytale
      rm -f downloader.zip
      chmod +x "$bin"

      # Behavioural integrity check, and the reason there is no hash pin: the
      # archive is a moving target (it carries the downloader's own self-update
      # mechanism), so "does it run" is a better test than "does it match a hash
      # we recorded three releases ago". A truncated download fails here rather
      # than at the point where somebody is waiting on an authorisation code.
      if ! "$bin" -version >/dev/null 2>&1; then
        echo "extracted downloader does not run; refusing to keep it" >&2
        exit 1
      fi

      echo "installed $("$bin" -version)"
    '';
  };

  # -------------------------------------------------------------------------
  # Authenticating and downloading the server payload
  # -------------------------------------------------------------------------
  #
  # NOT wantedBy anything, and that is the point: this unit requires a human with
  # a browser, once. It is started by hand:
  #
  #   systemctl start hytale-download        # inside the container
  #
  # or from the host:
  #
  #   incus exec homelab:hytale -- sudo -u hytale \
  #     /var/lib/hytale/${downloaderBin}
  #
  # running the binary directly is the better shape for the first run, because
  # the downloader's device-code flow prints a URL and a code and then polls --
  # it does not need a TTY, but a terminal makes the output readable while it
  # waits. After the first success this unit can be re-run unattended forever,
  # because the credentials it left behind refresh themselves.
  #
  # `-credentials-path` rather than relying on the default, which is
  # `$CWD/.hytale-downloader-credentials.json`. The default would put the token
  # on hytale-data, where the hourly btrfs snapshots would each hold a copy of
  # it; pointing it at hytale-secrets is the whole reason that volume exists.
  #
  # `-download-path` writes a zip and does NOT extract it, despite the name and
  # despite upstream's docs implying the CLI "sets up this layout automatically".
  # So the extraction is here, and it is verified rather than assumed: the unit
  # fails if the jar or the assets are not where the server will look for them,
  # instead of leaving hytale.service to fail later with a classpath error.
  systemd.services.hytale-download = {
    description = "Authenticate with Hytale and download the server payload (interactive, run by hand)";
    after = [
      "hytale-dirs.service"
      "hytale-downloader.service"
      "network-online.target"
    ];
    requires = [ "hytale-dirs.service" "hytale-downloader.service" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.unzip
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "hytale";
      Group = "hytale";
      WorkingDirectory = "/var/lib/hytale";
    };
    script = ''
      set -euo pipefail

      zip=/var/lib/hytale/game.zip

      echo "downloading the current release; open the URL it prints and authorise."
      echo "credentials land at ${credentialsPath}"
      /var/lib/hytale/${downloaderBin} \
        -credentials-path ${credentialsPath} \
        -download-path "$zip" \
        -skip-update-check

      [ -s "$zip" ] || { echo "downloader produced no archive" >&2; exit 1; }

      # Extract over the working directory. The archive's own layout is
      # Assets.zip + start.sh + start.bat + Server/, which is exactly where the
      # server expects them, so this needs no path arithmetic.
      unzip -o -q "$zip" -d /var/lib/hytale
      rm -f "$zip"

      # Verify what the server will actually look for, in the place it will
      # actually look. A silent partial extraction here becomes a crash loop in
      # hytale.service that names neither the zip nor the download.
      missing=0
      for f in Server/HytaleServer.jar Assets.zip; do
        if [ ! -s "/var/lib/hytale/$f" ]; then
          echo "MISSING: /var/lib/hytale/$f" >&2
          missing=1
        fi
      done
      [ "$missing" -eq 0 ] || exit 1

      echo "server payload in place:"
      ls -la /var/lib/hytale
    '';
  };

  # -------------------------------------------------------------------------
  # The server
  # -------------------------------------------------------------------------
  #
  # Run directly rather than through the start.sh the payload contains, and that
  # is the one place this diverges from upstream's own launcher. Two reasons,
  # both about control:
  #
  #   * start.sh hardcodes `--backup --backup-dir backups --backup-frequency 30`
  #     and appends "$@" after it. The CLI overrides config.json, so the backup
  #     cadence could not be set to daily from anywhere -- not from config.json,
  #     not from this file -- without editing a downloaded, mutable script that
  #     nothing in this repository reviews. Thirty-minute archives of a 178 MB
  #     universe is ~8 GB/day replicated to Dendra, forever.
  #
  #   * start.sh exists to apply staged updates: the server downloads a new
  #     payload into updater/staging, exits 8, and the script copies it into
  #     place and loops. Under systemd that loop is redundant (Restart=
  #     below handles exit 8) but the copy step is not, so **/update apply does
  #     nothing here**. See "Updates" in README.md -- this is inherited from the
  #     k3s deployment, which also ran the jar directly, and is called out there
  #     rather than left to be discovered.
  #
  # WorkingDirectory is Server/ and that is not a preference. config.json,
  # universe/, mods/ and bans.json all live there, and the asset path is
  # relative to it: `../Assets.zip` is how the asset archive one level up is
  # found. Hytale's own start.sh does the same cd, for the same reason.
  #
  # --accept-early-plugins is carried over from the k8s deployment, which runs
  # with it and ships earlyplugins/NyoUpdates-2.1.1.jar. The flag is an
  # acknowledgement that early plugins are unsupported; without it the server
  # refuses to start rather than loading them.
  systemd.services.hytale = {
    description = "Hytale dedicated server";
    documentation = [ "https://support.hytale.com/hc/en-us/articles/45326769420827-Hytale-Server-Manual" ];
    wantedBy = [ "multi-user.target" ];
    after = [ "hytale-dirs.service" "hytale-downloader.service" ];
    requires = [ "hytale-dirs.service" ];
    path = [
      pkgs.openjdk25
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "simple";
      User = "hytale";
      Group = "hytale";
      WorkingDirectory = "/var/lib/hytale/Server";

      # No stdin. The k3s deployment gave the server a TTY and stdin because a
      # container image needs one to stay alive; systemd has no equivalent need,
      # and a server reading from a closed stdin is a server that can be shut
      # down by anything that closes a file descriptor.
      StandardInput = "null";

      # on-failure, not always: this also covers exit code 8, which Hytale uses
      # for "a staged update is ready, restart into it". Under the upstream
      # start.sh that is a `continue` in a loop; here it is systemd's restart
      # policy, which is the same thing with less machinery. Note that the
      # restart alone does not APPLY the staged update -- see the header.
      Restart = "on-failure";
      RestartSec = "15s";

      # QUIC keeps per-connection state, and the server opens a socket per
      # player plus listeners for its session and update services.
      LimitNOFILE = 65535;

      # SIGTERM is a graceful shutdown: the server flushes universe resources on
      # the way out, which is what makes the next start cheap. systemd's 90s
      # default would be a hard kill in the middle of a 178 MB flush, and a
      # flush killed halfway is the state the backups exist to protect against.
      KillSignal = "SIGTERM";
      TimeoutStopSec = "300";

      # 143 is SIGTERM, which is what systemd records if the stop above timed
      # out -- counted as success so a slow flush does not also report failure.
      SuccessExitStatus = "0 143";
    };

    # A script rather than ExecStart, for exactly one reason: the AOT cache flag
    # is conditional. Upstream recommends
    #
    #   java -XX:AOTCache=HytaleServer.aot -jar HytaleServer.jar
    #
    # but the layout this produces carries `HytaleServer.aot.config`, and the
    # flag names a path that does not exist. Passing it anyway is what the k3s
    # deployment did and it is a no-op the JVM merely warns about. So it is added
    # only when the file is actually there, which is the case for a payload laid
    # down by the downloader and is worth getting right either way.
    #
    # A plain string rather than an array, so the expansion is a plain
    # unquoted-split that behaves the same in sh and bash -- `set -u` is happy
    # with an empty-but-set variable either way, and the value contains no
    # whitespace, so there is nothing for the split to get wrong.
    script = ''
      set -euo pipefail

      aot=""
      if [ -f HytaleServer.aot ]; then
        aot="-XX:AOTCache=HytaleServer.aot"
      fi

      exec ${lib.getExe' pkgs.openjdk25 "java"} \
        ${javaOpts} \
        $aot \
        -jar HytaleServer.jar \
        --assets ../Assets.zip \
        --accept-early-plugins \
        --backup \
        --backup-dir backups \
        --backup-frequency ${toString backupFrequencyMinutes} \
        --backup-max-count ${toString backupMaxCount} \
        --backup-archive-max-count ${toString backupArchiveMaxCount}
    '';
  };

  # -------------------------------------------------------------------------
  # Pruning the archives
  # -------------------------------------------------------------------------
  #
  # This is the ONLY unit in this instance that deletes anything, and it exists
  # because Hytale cannot express an age-based retention. See backupKeepDays.
  #
  # Two details carried over from minecraft, both of which are the same lesson
  # learned there:
  #
  #   * maxdepth 1, so this cannot reach into backups/archive/ -- the tier
  #     Hytale's own (disabled) retention would have used. The directory is not
  #     written to in practice, and if it ever were, this should not be the thing
  #     that quietly empties it.
  #
  #   * Age, not count. -mtime +7 means "older than seven 24h periods", so the
  #     window is stable regardless of how often the server restarts or how many
  #     archives a burst produced.
  #
  # Pruning here does NOT delete anything on the peer. hytale-backups is
  # replicated as a sendonly folder, and a sendonly folder never applies a remote
  # deletion, so a pruned archive stays on Dendra forever. That is the right way
  # round for a backup, and it is also why the local window can be this short
  # without being the whole history.
  #
  # Nothing is stopped for this. The archives are immutable once written and the
  # prune only looks at names and mtimes, so there is no consistency requirement
  # and no reason to interrupt a running server. The hourly btrfs snapshots on
  # hytale-backups bound what a misfire here can cost.
  systemd.services.hytale-backup = {
    description = "Prune Hytale archives older than the retention window";
    path = [
      pkgs.findutils
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "hytale";
      Group = "hytale";
      WorkingDirectory = "/var/lib/hytale/Server";
    };
    script = ''
      set -euo pipefail

      backups=/var/lib/hytale/Server/backups

      if [ ! -d "$backups" ]; then
        echo "no backup directory yet; nothing to prune"
        exit 0
      fi

      echo "archives before: $(find "$backups" -maxdepth 1 -type f -name '*.zip' | wc -l)"
      find "$backups" -maxdepth 1 -type f -name '*.zip' \
        -mtime +${toString backupKeepDays} -print -delete
      echo "archives after:  $(find "$backups" -maxdepth 1 -type f -name '*.zip' | wc -l)"
    '';
  };

  systemd.timers.hytale-backup = {
    description = "Prune old Hytale archives daily";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 04:20, and deliberately not on the hour or on :00. minecraft-backup.timer
      # takes 04:00 and the host's restic ran at :37; 04:20 is clear of both and
      # randomisation is off so it cannot drift into them.
      OnCalendar = "*-*-* 04:20:00";

      # A container that was off at 04:20 still prunes when it comes back,
      # rather than quietly carrying an unbounded directory until the next boot
      # that happens to be awake at the right minute.
      Persistent = true;
      AccuracySec = "1m";
    };
  };

  # -------------------------------------------------------------------------
  # The replicated-folder marker
  # -------------------------------------------------------------------------
  #
  # Step 5 of the contract in ../syncthing/NOTES.md, and the only part of it
  # that is this instance's job. The hub mounts hytale-backups READ-ONLY, so it
  # can never write the marker Syncthing needs before it will scan a folder;
  # without it the folder sits "stopped" and nothing is ever replicated.
  #
  # `d` and not `f`, so it works whether Syncthing expects a directory or a file.
  # Ordered by path, so tmpfiles creates it before the units that write into the
  # volume, and it survives the volume being mounted empty. 989 is the uid from
  # the top of this file; hytale-dirs also creates it, because tmpfiles has
  # already run by the time a later boot reaches that unit.
  systemd.tmpfiles.rules = [
    "d /var/lib/hytale/Server/backups/.stfolder 0755 989 989 -"
  ];
}
