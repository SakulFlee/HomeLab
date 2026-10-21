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
    };

    # ONE script rather than an ExecStart plus an ExecStartPost, and that shape
    # is not stylistic. An earlier version of this unit carried the marker and
    # the machine-id pin in a hand-built
    #
    #   ExecStartPost = sh -c ${lib.escapeShellArg "..."}
    #
    # and escapeShellArg quotes for a SHELL. systemd parses ExecStartPost with
    # its own rules, and inside a single-quoted systemd string a backslash is
    # not an escape character -- so the '\'' that escapeShellArg emits for every
    # apostrophe terminates the quote early and systemd gives up:
    #
    #   Unbalanced quoting, ignoring: "/nix/store/...-coreutils/bin/sh -c 'set -euo pipefail"
    #   hytale-dirs.service: Unit configuration has fatal error, unit will not be started.
    #   Loaded: bad-setting (Reason: Unit hytale-dirs.service has a bad unit file setting.)
    #
    # The unit then refuses to load AT ALL, which is silent at the level that
    # matters: `systemctl --failed` is empty, multi-user.target is reached
    # cleanly, and journalctl -u hytale-dirs prints "No entries". Nothing
    # anywhere says a unit was broken. Only `systemctl status` shows it, in a
    # field nothing looks at.
    #
    # And it is not only tr -d '-' that did it. Every apostrophe in the comment
    # block -- HytaleContainer's, container's, systemd's -- broke the parse just
    # as effectively, so the hazard is invisible: a comment is not supposed to
    # be able to take a service down.
    #
    # The module's `script` option writes the body to its own file in the store
    # and points ExecStart at it, so there is no Exec*= line to quote. It also
    # makes the ordering the code implies rather than the order two attributes
    # happen to be written in, and matches every other unit in this file.
    script = ''
      set -euo pipefail

      # -- the mount points --------------------------------------------------
      install -d -m 0755 -o hytale -g hytale \
        /var/lib/hytale /var/lib/hytale/Server /var/lib/hytale/Server/backups \
        /var/lib/hytale-secrets

      # -- the Syncthing marker ----------------------------------------------
      # A separate step because `install -d` creates the directory and not its
      # contents, and the marker is a directory Syncthing insists on finding
      # before it will scan a folder. The hub mounts hytale-backups READ-ONLY
      # and so can never create it itself -- without this the folder sits
      # "stopped" in the WebUI and nothing is ever replicated.
      mkdir -p /var/lib/hytale/Server/backups/.stfolder

      # -- the machine id -----------------------------------------------------
      #
      # /etc/machine-id is pinned to the copy on hytale-data, and it is
      # load-bearing in a way that took three wrong answers to establish.
      #
      # WHAT IT IS FOR. `auth.enc` is encrypted with a key derived from the
      # machine's hardware UUID. On Linux that UUID comes from /etc/machine-id,
      # and the code path is:
      #
      #   EncryptedAuthCredentialStore.resolvePassphrases(Path)
      #     -> com/hypixel/hytale/common/util/HardwareUtil.getUUID()
      #     -> PBKDF2WithHmacSHA256 -> SecretKey
      #
      # EncryptedAuthCredentialStore.class references HardwareUtil directly. So
      # change /etc/machine-id and auth.enc stops decrypting:
      #
      #   [EncryptedAuthCredentialStore] Failed to decrypt credentials from
      #     auth.enc - file may be corrupted
      #
      # /etc/machine-id is mode 0444 on the instance ROOT filesystem, which
      # apply.sh replaces on every image change, and Incus generates a fresh one
      # each time. Unpinned, EVERY recreate therefore costs a device-code login:
      # someone opens a browser, prints an authorisation code, and types it into
      # a console. That is not theoretical -- it happened three times in one
      # session, and it is the reason the deploys felt dangerous.
      #
      # Proven rather than argued: the id was set back to the value in effect
      # when /auth login device last ran, the server was restarted, and the log
      # said
      #
      #   Authentication successful! Mode: OAUTH_STORE
      #   Token refresh scheduled in 3300 seconds
      #
      # with no browser involved. Same auth.enc, same 1407 bytes, different
      # machine-id.
      #
      # A NOTE ON GETTING HERE, because the file's history says the opposite
      # twice. It was first claimed that .machine-id and auth.enc "travel
      # together" -- right conclusion, wrong file. It was then "corrected" to
      # telemetry-only, on the grounds that grepping the jar for the literal
      # "machine-id" returns exactly one class, HardwareUtil, and that its
      # output feeds TelemetryDataCollector.generateMachineIdHash. That grep is
      # correct and the conclusion is still wrong, because the string simply
      # does not appear in the auth package -- it calls HardwareUtil.getUUID()
      # and inherits the path from there. HardwareUtil serves BOTH: telemetry
      # and the credential-store key. Searching for a literal to prove a
      # negative is how the wrong answer looked like a careful one.
      #
      # WHY NOT JUST PIN IT AND LIVE WITH IT. Pinning alone breaks journalctl:
      # journalctl resolves its search path from /etc/machine-id, and journald
      # has already written this boot under /var/log/journal/<boot-id>/, so
      # after the pin every query returns
      #
      #   No journal files were found.
      #
      # That was measured both ways on the same boot before being believed. The
      # fix is the symlink below rather than a compromise, because the pinned id
      # is CONSTANT -- the same value every boot -- so one stable name can point
      # at whichever directory journald is using this time.
      #
      # Not pinned before journald starts, which would be the other way to do
      # this: the image is built once and shared by every instance, so a static
      # id cannot be baked in.
      #
      # Also note `rm -f /etc/machine-id` + `install` fails at boot with EBUSY
      # ("Device or resource busy"), which fails this unit and takes hytale
      # service down with it, since that unit Requires= this one. /etc/machine-id
      # is NOT a bind mount -- /proc/self/mountinfo does not list it and stat
      # reports a regular file with one link -- and the same rm succeeds seconds
      # later, so whatever holds it only does so during startup. Rewriting the
      # inode in place does not depend on the unlink and works either way.
      mid=/var/lib/hytale/.machine-id
      if [ ! -s "$mid" ]; then
        echo "no machine id on the volume; generating one"
        tr -d "-" < /proc/sys/kernel/random/uuid > "$mid"
      fi
      pinned=$(tr -d "[:space:]" < "$mid")

      # What journald is using THIS boot, captured before the id changes.
      boot=$(tr -d "[:space:]" < /etc/machine-id)

      # Give journalctl a path under the id it is about to be asked for. Done
      # first, so there is no instant where the id is changed and the directory
      # is missing. rm -rf on a symlink removes the link, not the journal behind
      # it; and the guard keeps it from pointing a directory at itself on the
      # boot where the pinned id already happens to be the boot id.
      if [ "$boot" != "$pinned" ] && [ -d "/var/log/journal/$boot" ]; then
        rm -rf "/var/log/journal/$pinned"
        ln -s "/var/log/journal/$boot" "/var/log/journal/$pinned"
      elif [ "$boot" != "$pinned" ]; then
        # Loud on purpose. Skipping this silently costs the journal -- the pin
        # still lands, and every journalctl then returns "No journal files were
        # found", which reads like an empty log rather than a missing one. The
        # directory should always exist by now, because journald creates it
        # before multi-user.target; if it does not, something is wrong upstream
        # and that is worth a line in the journal of the run that fixed it.
        echo "WARNING: /var/log/journal/$boot is absent; journalctl will not find this boot's log under the pinned id $pinned" >&2
      fi

      # In place: touch creates it if absent and only bumps mtime otherwise, so
      # it cannot truncate before the write. 0444 is restored at the end because
      # it is the convention systemd sets.
      touch /etc/machine-id
      chmod 0644 /etc/machine-id
      printf '%s\n' "$pinned" > /etc/machine-id
      chown root:root /etc/machine-id
      chmod 0444 /etc/machine-id

      echo "machine id: $pinned (boot was $boot)"
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
  # on hytale-data, where the daily btrfs snapshots would each hold a copy of
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
      # -x/-y set a wide pane so that `tmux capture-pane` is useful when nobody
      # is attached, which is the normal state: Hytale's startup is full of very
      # long lines, and at the default 80 columns they wrap into unreadable
      # ladders. An attaching client overrides the size anyway.
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

      # -- no pipe-pane, because the server already logs itself ----------------
      #
      # tmux is here for the CONSOLE and nothing else. The log does not come from
      # the unit's stdout and never did: `tmux new-session -d` detaches, so the
      # JVM's stdout belongs to the tmux server and systemd sees none of it.
      #
      # Two attempts to route it into the journal were made and both are gone.
      #
      # The first, `tmux pipe-pane ... | systemd-cat -t hytale`, lost the log
      # silently: the unit reported "Started Hytale dedicated server" and
      # `journalctl -u hytale` showed that line and nothing else, for the whole
      # life of the server. Nothing errors; the log is simply absent, and absent
      # exactly when you want it -- reading why the server is unhappy.
      #
      # The second worked and was still wrong, twice over.
      #
      # pipe-pane forwards what tmux RENDERS, so the stream carries the pane's
      # control sequences and journald stores any field containing one as binary:
      #
      #   Oct 13 03:05:14 hytale hytale[584]: [140B blob data]
      #
      # for every line. A log that exists and cannot be read is barely better
      # than the missing one. Fixing that meant stripping CSI/OSC with sed and
      # tr in front of systemd-cat, which worked -- and then systemd-cat died
      # silently partway through the next idle gap, taking the consumer with it
      # while tmux still reported `pane_pipe=1`. Nothing logged the death; sed
      # and tr were still running, writing into a pipe with no reader. So the
      # arrangement had a single point of failure that reported success while
      # broken, which is the same failure shape as the unit that would not load,
      # and as the pin that blinded journalctl. Three today, all mine.
      #
      # What makes all of it unnecessary is that Hytale writes its own log:
      #
      #   Server/logs/2026-10-13_03-12-40_server.log
      #
      # one file per session, complete, unwrapped, and on hytale-data where the
      # daily btrfs snapshots cover it. Verified on the deployed server: the
      # current session's file is 362 KB and contains Universe ready!, Listening
      # on /0.0.0.0:5520 and Authentication successful! Mode: OAUTH_DEVICE --
      # the same content the console shows, without the JLine "> " prompt
      # prefixes and without the pane's wrap column.
      #
      # To read it:
      #
      #   incus exec homelab:hytale -- \
      #     tail -F /var/lib/hytale/Server/logs/$(ls -t /var/lib/hytale/Server/logs/*.log | head -1)
      #
      # The files are named for the session start, so the newest is the live one.
      # They are NOT pruned by anything here, unlike archives in backups/ --
      # Hytale's own retention governs this directory and nothing in this file
      # touches it.

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
  # and no reason to interrupt a running server. hytale-backups is deliberately
  # not snapshotted; the sendonly peer retains pruned archives, so a misfire
  # here is recoverable from Dendra without a second snapshot tier.
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

      # The outcome, decided once and acted on once at the end. Three states and
      # they must not be conflated:
      #
      #   done     an archive exists that this run asked for
      #   skipped  the server is not running, so there was nothing to ask
      #   failed   the server IS running and did not produce an archive
      #
      # The first version of this unit collapsed the last two into a log line
      # and exited 0 either way. It ran at 04:20, the console was wedged, no
      # archive appeared, and the unit reported
      #
      #   no archive appeared within 300s
      #   archives before: 1 / archives after: 1
      #   Result=success
      #
      # Which is the "reports success while broken" shape that has now cost this
      # instance three times: a unit that would not load, a machine-id pin that
      # blinded journalctl, and this. So `failed` exits non-zero and lands in
      # `systemctl --failed`, where it is visible without reading a log.
      #
      # `skipped` deliberately still exits 0, and that is not an inconsistency.
      # The unit cannot archive without a server, so failing every time the game
      # is deliberately switched off would train everyone to ignore it. An
      # outage that keeps the server down costs a missed archive, and
      # Persistent=true on the timer runs it when the container comes back.
      outcome=failed
      detail=""

      # -- the archive ------------------------------------------------------
      #
      # Skipped, not failed, when the server is down -- for the reason above.
      if ! systemctl is-active --quiet hytale.service; then
        outcome=skipped
        detail="hytale.service is not running"
        echo "$detail; archiving nothing"
      elif ! tmux has-session -t "$session" 2>/dev/null; then
        # The service is active but its console is gone, which means the
        # supervision loop has not noticed yet or tmux died under it. Either way
        # there is no console to type into, so there is no backup -- and this is
        # a failure, not a skip, because the server IS meant to be running.
        detail="hytale.service is up but the tmux console is missing"
        echo "$detail; archiving nothing" >&2
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
        # until TimeoutStartSec: the zip is ~178 MB and took 10s in practice, so
        # 300s is generous rather than tight.
        deadline=$(( SECONDS + 300 ))
        while [ $SECONDS -lt $deadline ]; do
          # Newest archive newer than this run started.
          if [ -n "$(find "$backups" -maxdepth 1 -type f -name '*.zip' -newermt '-10 minutes' -print -quit 2>/dev/null)" ]; then
            outcome=done
            break
          fi
          sleep 10 &
          wait $! || true
        done

        if [ "$outcome" != done ]; then
          detail="no archive appeared within 300s"

          # Distinguish "the server heard us and refused" from "the console is
          # deaf". They are different faults and look identical from here: in
          # both cases send-keys delivers bytes to the pty and nothing comes
          # back. On the 04:20 run the console had stopped reading entirely --
          # /backup AND /help were echoed by the pty with no response -- and the
          # only reason that was diagnosable at all was a manual probe.
          #
          # So probe. /help is harmless, always available, and prints a long
          # block followed by the prompt, so "did the prompt come back" is a
          # usable signal. capture-pane -S - gives scrollback, because the
          # answer may be above the visible pane.
          #
          # This is a diagnosis, not a repair. Restarting the server here would
          # disconnect players over a missed backup, which is the wrong trade --
          # the backup is recoverable by running it again, the session is not.
          tmux send-keys -t "$session" '/help' Enter
          sleep 6
          if tmux capture-pane -p -S -40 -t "$session" 2>/dev/null | grep -qE '^\s*>\s*$'; then
            detail="$detail; the console answered /help, so the server is refusing the backup or is not writing one"
          else
            detail="$detail; the console did not answer /help either, so it is not reading input -- restart hytale.service by hand"
          fi
          echo "$detail" >&2
        fi
      fi

      # -- the prune --------------------------------------------------------
      #
      # Run even after a failure. Deleting nothing is not the same as doing
      # nothing useful, and the prune only reads names and mtimes, so it is safe
      # to run while the archive half is broken.
      if [ ! -d "$backups" ]; then
        echo "no backup directory yet; nothing to prune"
      else
        echo "archives before: $(find "$backups" -maxdepth 1 -type f -name '*.zip' | wc -l)"
        find "$backups" -maxdepth 1 -type f -name '*.zip' \
          -mtime +${toString backupKeepDays} -print -delete
        echo "archives after:  $(find "$backups" -maxdepth 1 -type f -name '*.zip' | wc -l)"
      fi

      # -- the verdict ------------------------------------------------------
      #
      # One line, because `systemctl show -p Result` and the last thing anyone
      # reads should agree. Skipped is the only non-success that is not a
      # failure, and it says so.
      case $outcome in
        done)
          newest=$(find "$backups" -maxdepth 1 -type f -name '*.zip' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
          size=$(stat -c %s "$newest" 2>/dev/null || echo "?")
          echo "OK: archive $newest ($size bytes)"
          exit 0
          ;;
        skipped)
          echo "SKIPPED: $detail"
          exit 0
          ;;
        *)
          echo "FAILED: $detail" >&2
          exit 1
          ;;
      esac
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
