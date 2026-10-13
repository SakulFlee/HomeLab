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
  # Hytale's OWN scheduler is effectively switched off, and `hytale-backup.timer`
  # presses the button instead. The frequency below is a year for that reason,
  # not as a policy statement.
  #
  # It has to be a large number rather than an absent flag, because `/backup`
  # refuses to run when no backup directory is configured:
  #
  #   BackupCommand: getConfig().getBackupConfig().getDirectory()
  #                 server.commands.backup.notConfigured
  #
  # and enabling backups is what creates that configuration. So the server is
  # told backups exist and where they go, with a period it will never reach.
  #
  # Why not leave Hytale to schedule itself, which is what the first version of
  # this file did at 1440 minutes? Because it does not survive a restart.
  # `Universe` calls
  #
  #   SCHEDULED_EXECUTOR.scheduleWithFixedDelay(runner, initialDelay, delay, MINUTES)
  #
  # during startup, so the countdown is rebuilt from zero on every boot -- and
  # the initial delay is the period, not zero, which is observable: a server
  # started with --backup-frequency 1440 logged
  #
  #   [Universe|P] Scheduled backup to run every 1440 minute(s)
  #
  # and produced no archive at all over the following quarter of an hour. A
  # server restarted inside the window therefore NEVER backs up, and silently,
  # because an empty backups/ directory is indistinguishable from "not due yet".
  # On this host that is not a hypothetical: incus-apply-<name>.path fires on
  # every git pull and any image change recreates the instance.
  #
  # Driving `/backup` from a timer is calendar-driven and restart-proof, and it
  # costs nothing in consistency: BackupCommand calls Universe.runBackup(), which
  # is the SAME method the built-in scheduler calls, so the flushAll() before the
  # zip -- the reason this server can be backed up while players are online --
  # still happens. Only who presses the button, and when, changes.
  #
  # The two counts are set absurdly high on purpose. They are Hytale's retention
  # and this instance does not use them: `hytale-backup.timer` deletes by age
  # instead, which is a policy Hytale cannot express. Leaving these at their
  # defaults would mean two independent prunes racing over one directory, and
  # Hytale's would win the race by archiving rather than deleting -- moving
  # files into backups/archive/ that nothing then prunes.
  # 365 days: long enough that the built-in scheduler never fires, short enough
  # to stay inside the option's own integer range.
  backupFrequencyMinutes = 525600;
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
  #
  # tmux because the server runs inside a session of it, and the session is the
  # only administration channel this software has -- no RCON, no HTTP admin. See
  # the hytale.service header for why it is a tmux session rather than a FIFO.
  environment.systemPackages = with pkgs; [
    curl
    jq
    openjdk25
    tmux
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
  #
  # The shell is bash, NOT the nologin NixOS gives a system user by default, and
  # that is load-bearing rather than cosmetic. tmux runs a session's command
  # through the user's LOGIN SHELL -- `$SHELL -c '<command>'` -- so a nologin
  # shell makes every session die the instant it is created:
  #
  #   nologin[1040]: Attempted login by UNKNOWN (UID: 989) on /dev/pts/1
  #   hytale.service: Main process exited, code=exited, status=1/FAILURE
  #
  # in a 15-second loop, with the real cause nowhere in the unit's own output.
  # Found by deploying it, not by reading it.
  #
  # A real shell on a passwordless, SSH-less system account is not a login
  # surface: the account has no password, services.openssh is off, and nothing
  # forwards port 22. It is only here because a supervisor needs somewhere to
  # run a command from.
  users.users.hytale = {
    isSystemUser = true;
    group = "hytale";
    uid = 989;
    shell = pkgs.bash;
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

    # Both of these run as root, after the directories above exist and before
    # anything writes into them. They are ExecStartPost rather than the
    # module's `postStart` because that option execs its strings directly --
    # systemd has no shell in ExecStartPost -- and two of the four things below
    # are conditionals.
    serviceConfig.ExecStartPost = lib.getExe' pkgs.coreutils "sh"
      + " -c "
      + lib.escapeShellArg ''
        set -euo pipefail

        # -- the Syncthing marker --------------------------------------------
        # install -d above cannot make this: it creates the directory but not
        # its contents, and the marker is a directory Syncthing insists on
        # finding before it will scan a folder. The hub mounts hytale-backups
        # READ-ONLY and so can never create it itself -- without this the folder
        # sits "stopped" in the WebUI and nothing is ever replicated.
        mkdir -p /var/lib/hytale/Server/backups/.stfolder

        # -- the machine id --------------------------------------------------
        #
        # Parity with the container image this replaces. HytaleContainer's
        # entrypoint.sh does exactly this, and it is worth reading before
        # changing it:
        #
        #   if [ ! -f /opt/hytale/.machine-id ]; then
        #     cat /proc/sys/kernel/random/uuid | tr -d '-' > /opt/hytale/.machine-id
        #   fi
        #   cat /opt/hytale/.machine-id | tee /etc/machine-id
        #
        # So the volume-root file is the SOURCE OF TRUTH and /etc/machine-id is
        # derived from it on every start. Nothing in the server reads the
        # former -- grepping the whole 0.7.0 jar for the literal "machine-id"
        # returns exactly one class, com/hypixel/hytale/common/util/HardwareUtil,
        # and it reads /etc/machine-id (plus /var/lib/dbus/machine-id and
        # /sys/class/dmi/id/product_uuid) to build a hardware UUID that
        # TelemetryDataCollector SHA-256s into a `machineIdHash` packet field.
        #
        # In other words: telemetry only. It is NOT a key, it has nothing to do
        # with auth.enc, and an earlier version of this file's README claimed
        # otherwise by reading the two files' co-location as intent. The
        # bytecode says telemetry, so the README says telemetry now.
        #
        # The reason it exists in Docker is that a container inherits its host's
        # /etc/machine-id, so every container on the box would otherwise
        # report the same machine.
        #
        # Incus does not have that problem -- each instance gets its own, and
        # they were checked: this one is 966e7fde..., the host is 563da553...,
        # minecraft is 088fec56.... So the UNIQUENESS the entrypoint was
        # buying is already free here, and this block is not needed to make the
        # id unique.
        #
        # What it IS needed for is the other half: /etc/machine-id lives on the
        # instance's ROOT filesystem, which apply.sh replaces wholesale on every
        # image change, so Incus's generated id is stable across a restart and
        # changes on every recreate. Pinning it to a file on hytale-data makes
        # the identity survive deploys, which is the property the Docker
        # deployment had and this would otherwise quietly lose.
        #
        # Keeping the id that came across from k3s is deliberate. It is the same
        # game server, the same world and the same licence, so Hypixel's
        # telemetry should see one machine rather than a second one appearing in
        # LXC and the first one vanishing.
        #
        # The one thing this cannot do is be consistent from the first line of
        # boot: systemd reads /etc/machine-id before this unit runs, so within a
        # given boot journald and dbus keep the id they started with and only
        # later readers see this one. That is also what happens under Docker,
        # where the entrypoint runs after init, and it costs nothing.
        mid=/var/lib/hytale/.machine-id
        if [ ! -s "$mid" ]; then
          echo "no machine id on the volume; generating one"
          tr -d '-' < /proc/sys/kernel/random/uuid > "$mid"
        fi
        echo "machine id: $(cat "$mid")"

        # /etc/machine-id is mode 0444 by convention (systemd creates it that way
        # so nothing edits it casually), so replace rather than overwrite.
        rm -f /etc/machine-id
        install -m 0444 -o root -g root "$mid" /etc/machine-id
      '';
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
      pkgs.tmux
      pkgs.systemd
    ];
    serviceConfig = {
      Type = "simple";
      User = "hytale";
      Group = "hytale";
      WorkingDirectory = "/var/lib/hytale/Server";

      # stdin is /dev/null, and that is deliberate even though the server runs
      # inside tmux below. Nothing writes to this unit's stdin; the server's
      # console is the tmux session, and a stray writer to this fd cannot reach
      # it. A server reading a closed stdin is a server that can be shut down by
      # anything that closes a file descriptor.
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

    # -------------------------------------------------------------------------
    # Why tmux
    # -------------------------------------------------------------------------
    #
    # Hytale has no RCON, no HTTP admin API and no query endpoint. `Options` in
    # 0.6.8 and 0.7.0 were both checked; the only match for any of those is
    # Hypixel's own "Session token for Session Service API". **stdin is the only
    # administration channel this server has**, which is why the k3s deployment
    # ran it with `stdin: true, tty: true`.
    #
    # So it needs a console, and there are two ways to give it one. A FIFO on
    # stdin works and is smaller, and it was the first version of this file. It
    # relies on JLine falling back to a dumb terminal when stdin is not a TTY --
    # ConsoleModule uses org.jline's TerminalBuilder and LineReaderBuilder on a
    # dedicated ConsoleThread, and the fallback exists, but it is an assumption
    # about a library's behaviour on the one path the whole server depends on.
    #
    # tmux removes the assumption: it hands java a REAL pty, which is the
    # configuration this software is known to work in, because that is what k3s
    # gave it. It also gives something the FIFO never could -- an attachable
    # console:
    #
    #   incus exec homelab:hytale -- sudo -u hytale tmux attach -t hytale
    #
    # which is what makes `/auth login device` possible without stopping the
    # server. That matters more than it sounds: Hytale's auth certificates
    # expire about hourly, and an outage longer than that loses the server's
    # authenticated identity outright.
    #
    # Three costs, all of them real:
    #
    #   * tmux becomes the parent of the JVM. If the tmux server dies, java gets
    #     SIGHUP; the supervision loop below then exits and systemd restarts the
    #     unit. Recoverable, but it is one more thing that can take the server
    #     down.
    #   * `tmux new-session` needs a terminal, so under systemd it must be -d,
    #     which returns immediately -- and systemd would conclude the service
    #     exited. Hence the supervision loop.
    #   * A restart must kill any session left over first, or `new-session`
    #     fails on the duplicate name and the unit crash-loops until noticed.
    script = ''
      set -euo pipefail

      session=hytale

      # A stale session from a previous run would make new-session fail. -t is
      # the target; the guard keeps `set -e` from killing the unit over it.
      tmux kill-session -t "$session" 2>/dev/null || true

      aot=""
      if [ -f HytaleServer.aot ]; then
        aot="-XX:AOTCache=HytaleServer.aot"
      fi

      # -d because there is no terminal here. -c because WorkingDirectory
      # applies to this script, not to the shell tmux spawns.
      #
      # -x/-y set a wide pane on purpose. The JVM's stdout goes to the PANE, not
      # to this unit, and what pipe-pane forwards to the journal below is the
      # pane's rendered output -- so the pane width is the log's wrap column.
      # Hytale's startup is full of very long lines (asset warnings dump whole
      # JSON records), and at the default 80 columns they wrap into unreadable
      # ladders. 300 costs nothing and removes most of it.
      tmux new-session -d -s "$session" -c /var/lib/hytale/Server \
        -x 300 -y 60 \
        "${lib.getExe' pkgs.openjdk25 "java"} ${javaOpts} $aot \
          -jar HytaleServer.jar \
          --assets ../Assets.zip \
          --accept-early-plugins \
          --backup \
          --backup-dir backups \
          --backup-frequency ${toString backupFrequencyMinutes} \
          --backup-max-count ${toString backupMaxCount} \
          --backup-archive-max-count ${toString backupArchiveMaxCount}"

      # Put the server's output back in the journal.
      #
      # `tmux new-session -d` DETACHES, so the JVM's stdout belongs to the tmux
      # server rather than to this unit, and systemd never sees a byte of it.
      # The first deployed version of this file had exactly that, and the
      # symptom is quiet: the unit reports
      #
      #   Started Hytale dedicated server.
      #
      # and `journalctl -u hytale` then shows that line and nothing else, for
      # the whole life of the server. Nothing errors; the log is simply gone,
      # and it is gone precisely when you most want it -- reading why the
      # server is unhappy. Found by deploying it.
      #
      # pipe-pane tees the pane to systemd-cat, so the log is searchable in the
      # journal again, under the `hytale` syslog identifier:
      #
      #   journalctl -t hytale -f
      #
      # -o means "from now on", so the handful of lines between new-session and
      # this call are the only thing not captured, which is nothing.
      tmux pipe-pane -o -t "$session" \
        "${lib.getExe' pkgs.systemd "systemd-cat"} -t hytale"

      # Stay in the foreground so systemd tracks the server's lifetime: this
      # loop ends exactly when the tmux session does.
      #
      # `sleep 5 & wait $!` rather than a plain `sleep`, and that is the whole
      # trick. A foreground sleep does not return until it finishes, so SIGTERM
      # is not delivered to anything until the sleep ends -- the stop would hang
      # for the remainder of the interval and then hit TimeoutStopSec, turning
      # every restart into a 300s kill in the middle of a world flush.
      # Backgrounding the sleep and waiting for it puts a shell builtin in the
      # foreground, and wait returns the moment the signal arrives.
      while tmux has-session -t "$session" 2>/dev/null; do
        sleep 5 &
        wait $! || true
      done

      # Reaching here means the session ended on its own: the JVM exited. That
      # covers a crash and Hytale's exit code 8 ("staged update ready"), and both
      # want a restart -- which is what Restart=on-failure is for.
      #
      # So this MUST be a non-zero exit. An earlier version ended with `exit 0`,
      # reasoning that the loop ending was not itself an error. That silently
      # disarmed the restart policy: the JVM would crash, tmux would drop the
      # session, the loop would finish successfully, systemd would record a
      # clean stop, and the game server would stay down until the next deploy.
      #
      # A deliberate `systemctl stop` never gets here -- systemd SIGTERMs this
      # script while it is in the wait below, and bash has no trap, so it dies
      # from the signal instead of falling out of the loop. That asymmetry is
      # what lets one exit code mean "restart" without also meaning "ignore the
      # operator".
      exit 1
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
  #
  # It also ASKS for one, through the tmux console, and that is the part this
  # unit exists for. See backupFrequencyMinutes for why the server's own
  # scheduler is not trusted with the cadence.
  systemd.services.hytale-backup = {
    description = "Take a Hytale universe archive, then prune the old ones";
    path = [
      pkgs.findutils
      pkgs.coreutils
      pkgs.tmux
      pkgs.systemd
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
      session=hytale

      # -- the archive ------------------------------------------------------
      #
      # Skipped, not failed, when the server is down -- deliberately, and for
      # the same reason minecraft-backup does not start a server somebody
      # stopped. Persistent=true on the timer means the run happens when the
      # container comes back, so an outage costs a missed archive rather than a
      # failed unit that nobody reads.
      #
      # Failing the unit instead would be worse than useless here: the unit
      # cannot archive without a server, so it would fail every night the game
      # is deliberately switched off.
      if ! systemctl is-active --quiet hytale.service; then
        echo "hytale.service is not running; archiving nothing"
      elif ! tmux has-session -t "$session" 2>/dev/null; then
        # The service is active but its console is gone, which means the
        # supervision loop has not noticed yet or tmux died under it. Either way
        # there is no console to type into, so there is no backup.
        echo "hytale.service is up but the tmux console is missing; archiving nothing" >&2
      else
        echo "asking the server for an archive"
        tmux send-keys -t "$session" '/backup' Enter

        # The archive is asynchronous: /backup returns as soon as it is queued,
        # and the work happens on the server's own thread. Waiting for it here
        # is what makes the prune below see a settled directory, and it makes
        # this unit's success mean "an archive exists" rather than "a key was
        # typed".
        #
        # Bounded, because a server that never answers must not hang the unit
        # until TimeoutStartSec: the zip is ~175 MB and took well under a
        # minute in practice, so 300s is generous rather than tight.
        deadline=$(( SECONDS + 300 ))
        while [ $SECONDS -lt $deadline ]; do
          # Newest archive newer than this run started.
          if [ -n "$(find "$backups" -maxdepth 1 -type f -name '*.zip' -newermt '-10 minutes' -print -quit 2>/dev/null)" ]; then
            echo "archive written"
            break
          fi
          sleep 10 &
          wait $! || true
        done

        if [ -z "$(find "$backups" -maxdepth 1 -type f -name '*.zip' -newermt '-10 minutes' -print -quit 2>/dev/null)" ]; then
          echo "no archive appeared within 300s" >&2
        fi
      fi

      # -- the prune --------------------------------------------------------
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
    description = "Archive the Hytale universe and prune old archives, daily";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 04:20, and deliberately not on the hour or on :00. minecraft-backup.timer
      # takes 04:00; 04:20 is clear of it and randomisation is off so it cannot
      # drift in.
      OnCalendar = "*-*-* 04:20:00";

      # A container that was off at 04:20 still runs when it comes back, rather
      # than quietly going a day without an archive -- which is the failure this
      # whole unit was rewritten to remove.
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
