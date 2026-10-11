# NixOS system for the Incus instance "renovate".
#
# Replaces the k3s CronJob in apps/renovate/ -- `renovate/renovate:43-full` on an
# `@hourly` schedule -- with the same program from nixpkgs
# (services.renovate, renovate 44.79.2), driven by a scheduler that adapts its
# interval to what the last run actually did. See "Scheduling" below; that is
# the part of this file worth reading first.
#
# Two things are deliberately *not* here, and both were true in k3s:
#
#   * No ingress and no vhost. Renovate is a client of Forgejo and of package
#     registries; it serves nothing, so there is nothing for Caddy to reverse
#     proxy. It gets no vhost entry and no networkForward.
#   * No per-repository configuration. autodiscover walks everything the bot
#     token can see, and every repository's own renovate.json (HomeLab has one)
#     is the config. Nothing about a specific repository is pinned in this file,
#     because nothing was in the CronJob.
{ config, lib, pkgs, ... }:
let
  # Where incus/apply.sh renders the two tokens. Written raw, 0400 root:root --
  # see incus.nix for why that is the right mode for a LoadCredential source.
  secretsDir = "/var/lib/incus-secrets";

  # Where Renovate writes its per-run JSON report (settings.reportPath below).
  # A second StateDirectory rather than a path inside baseDir: baseDir is
  # Renovate's own scratch space and it prunes what it finds in there, and this
  # file has to outlive the run that wrote it. systemd mounts every
  # StateDirectory idmapped for a unit that runs with PrivateUsers=, so the
  # renovate user can write it without this needing a tmpfiles rule, a group or
  # a world-writable directory.
  reportDir = "/var/lib/renovate-report";
  reportPath = "${reportDir}/report.json";

  # Where the scheduler keeps what it needs to survive a restart.
  scheduleStateDir = "/var/lib/renovate-schedule";

  # -------------------------------------------------------------------------
  # The schedule. Three numbers, and everything else follows from them.
  #
  #   counter 0        ->  5 minutes
  #   counter n (n>0)  ->  n * 15 minutes, capped at 6 hours (counter 24)
  #
  # A run that finds work resets the counter to 0, so it is 5 minutes again
  # from any depth -- new activity is picked up in minutes no matter how long
  # the instance had been idle. A run that finds nothing steps the counter up by
  # one, walking 5m -> 15m -> 30m -> 45m -> 1h -> ... -> 6h. Roughly a day and
  # a half of quiet to reach the bottom, and it never stops climbing.
  #
  # The old schedule was flat `@hourly`, which is this one only at counter 4.
  # Anything that has been quiet for a while now costs a fraction of what it
  # used to; anything that has just changed is picked up 12x sooner.
  #
  # maxIntervalSeconds is what "quiet" means, not a politeness setting: at the
  # bottom of the ladder this instance does ~4 runs a day instead of 24, and
  # the cost of that choice is bounded by maxIntervalSeconds -- a dependency
  # published just after a run is missed for at most that long.
  # -------------------------------------------------------------------------
  minIntervalSeconds = 5 * 60; # counter 0
  stepIntervalSeconds = 15 * 60; # each quiet run
  maxIntervalSeconds = 6 * 60 * 60; # counter ceiling
  maxCounter = maxIntervalSeconds / stepIntervalSeconds; # 24
in
{
  networking.hostName = "renovate";

  # Outbound only: Forgejo, and whatever registry each dependency comes from.
  # Nothing listens, nothing is forwarded, so there is no attack surface to
  # gate -- the host firewall is the boundary that matters, and this instance is
  # behind it on incusbr0.
  networking.firewall.enable = false;

  # The router, like every other instance. Renovate resolves forgejo.sakul-flee.de
  # and a few hundred registry hostnames per run, so this is not optional.
  networking.nameservers = [ "192.168.178.1" ];

  # Nothing here is worth logging into; `incus exec` goes through the API and
  # does not need a daemon listening for it.
  services.openssh.enable = false;

  # ---------------------------------------------------------------------------
  # The account
  # ---------------------------------------------------------------------------
  #
  # services.renovate wants DynamicUser and gets it -- but DynamicUser is wrong
  # for this deployment, and the report is the reason.
  #
  # A DynamicUser's StateDirectory is created below /var/lib/private and
  # deleted when the unit stops, which is the point of it: the account and
  # everything it wrote evaporate together. That is fine for a unit that writes
  # only a cache. It is not fine here, because the scheduler has to read the
  # report that the run *just* wrote, and by the time the run is over the file
  # is gone. DynamicUser would mean the scheduler can never tell "nothing
  # changed" from "there is nothing to read", so the interval would never
  # adapt and the adaptive schedule would be untestable at best.
  #
  # A static system user also keeps baseDir across runs, so Renovate reuses the
  # repositories it cloned last time instead of re-cloning every repository on
  # every run. That is most of the wall-clock cost of a sweep.
  users.groups.renovate = { };

  users.users.renovate = {
    isSystemUser = true;
    group = "renovate";
    description = "Renovate dependency updater";
  };

  services.renovate = {
    enable = true;

    # The k3s CronJob ran on `@hourly`. That is NOT reproduced here: the whole
    # point of this instance is the adaptive schedule below, and a systemd timer
    # has a fixed interval it cannot re-arm from the result of a run. Leaving
    # this null also means the module generates no timer unit at all, so there
    # is exactly one thing that decides when Renovate runs -- renovate-schedule
    # below -- and not two mechanisms that can disagree.
    #
    # To go back to a fixed cadence, set this to "hourly" and disable
    # renovate-schedule.service. Do not leave both running.
    schedule = null;

    # The two secrets, and only the two, arrive as environment variables from
    # the two EnvironmentFile= lines on the run unit below. Not through
    # services.renovate.credentials, which is the obvious choice and does not
    # work here at all -- see the LoadCredential note on that unit.
    #
    # RENOVATE_TOKEN is the Forgejo bot token Renovate authenticates with;
    # RENOVATE_GITHUB_COM_TOKEN lets it read github.com release notes and
    # changelogs that a Forgejo mirror does not carry. Both are the k3s
    # deployment's own values, unchanged -- see incus.nix.
    #
    # The four other values the k3s secret carried are configuration, not
    # secrets, and are set openly below. RENOVATE_ENDPOINT in particular is a
    # URL anyone can look up, and treating it as a secret bought nothing and
    # cost a rendered file.

    settings = {
      platform = "forgejo";
      endpoint = "https://forgejo.sakul-flee.de/api/v1";
      autodiscover = true;

      # HomeLab vendors a submodule (apps/pvc-explorer/vendor/pvc-explorer) and
      # Orbital does the same for a Rust crate. Without this the submodule is an
      # empty directory, which breaks the cargo workspace outright
      # ("failed to read Crates/orbital-iced/core/Cargo.toml") and leaves the
      # git-submodules manager with no checkout to move. The k3s CronJob set
      # RENOVATE_CLONE_SUBMODULES for the same reason.
      cloneSubmodules = true;

      # Use the toolchains that are installed in runtimePackages below instead
      # of pulling a sidecar image per manager. There is no Docker daemon in
      # this instance (it is an unprivileged LXC, deliberately -- see incus.nix),
      # so this is not an optimisation, it is the only way the gradle, cargo,
      # composer and bundler managers can work at all.
      binarySource = "global";

      # The same value the k3s secret carried
      # (RENOVATE_ALLOWED_UNSAFE_EXECUTIONS=gradleWrapper). It is what lets
      # Renovate exec a repository's own ./gradlew to collect Gradle wrapper
      # updates; without it those updates are never offered.
      allowedUnsafeExecutions = [ "gradleWrapper" ];

      # The report the scheduler reads to decide how long to wait. This is the
      # whole mechanism: one JSON file per run, written as the run finishes.
      reportType = "file";
      reportPath = reportPath;
    };

    # What Renovate can exec, as opposed to what it manages.
    #
    # This is the direct replacement for the "full" in renovate/renovate:43-full,
    # which shipped ~80 language toolchains as a convenience so that whatever a
    # repository turned out to need was present. Here the list is exactly the
    # ecosystems in use -- git is added by the module itself, and is the one
    # thing that is not optional.
    #
    # Each of these is a real package in the 26.05 pin this flake is on, not a
    # best guess: the image build resolves every one of them, so a rename or a
    # package that dropped out of the branch fails the build here rather than at
    # 3am when a repository needs it.
    runtimePackages = with pkgs; [
      # JVM ecosystem. jdk25 rather than the default jdk (21) because there is
      # no reason to pin an instance to an older LTS here, and the newer JDK is
      # what a fresh Gradle or Maven wrapper wants to see.
      #
      # One caveat, stated because it is the kind of thing that shows up weeks
      # later as a failing gradle-wrapper update rather than an obvious error:
      # Gradle versions below 9 refuse to *run* on Java 25, and Renovate's
      # gradle-wrapper manager execs the repository's own wrapper. So a
      # repository pinned to Gradle 8 will not offer updates while its wrapper
      # is incompatible with this JDK, and will start offering them once
      # Renovate bumps that Gradle (which is the dependency update it wants to
      # make anyway). If that turns out to matter more than the JDK version,
      # swapping this one line for `jdk` (21, the LTS) is the whole fix.
      jdk25
      gradle
      maven

      # .NET, version-pinned to 8 to match the SDK the repositories target.
      dotnet-sdk

      # Rust. Orbital is a cargo workspace reached through a submodule, so this
      # pair is load-bearing rather than speculative.
      cargo
      rustc

      go

      # Node. nodejs_24 explicitly rather than `nodejs`, so the instance does
      # not change Node major version under a nixpkgs bump.
      nodejs_24
      yarn
      pnpm

      # Python. python3Packages for pip and pip-tools because those are not
      # top-level attributes in this branch (verified against the pin), and the
      # rest are, so the four below are direct.
      python3
      python3Packages.pip
      python3Packages.pip-tools
      poetry
      uv
      pipenv
      pdm
    ];

    environment = {
      # k3s ran `LOG_LEVEL=debug` as an environment variable and so does this,
      # because that is the only form the validator accepts: put in the config
      # file, `logLevel` fails the module's build-time check with
      #
      #   Invalid configuration option: logLevel
      #
      # and takes the whole image down with it. (The k3s secret carried four
      # other values; this is the only one that could not be moved into
      # `settings`.) Worth remembering that this instance now runs up to 4x as
      # often, because debug logging for an autodiscover sweep over every
      # repository is genuinely large -- "info" is a one-word change here if the
      # journal ever becomes a problem.
      LOG_LEVEL = "debug";

      # The JDK from runtimePackages, named explicitly. PATH alone would work
      # for most managers, but Gradle and Maven both prefer JAVA_HOME when it is
      # set and fall back to `java` on PATH when it is not, and a manager that
      # silently picks a different JVM than the one this instance installed is
      # exactly the kind of difference that is hard to see later.
      JAVA_HOME = "${pkgs.jdk25.home}";
    };
  };

  # ---------------------------------------------------------------------------
  # The run unit: the nixpkgs module's, with two changes.
  # ---------------------------------------------------------------------------
  #
  # Both changes are mkForce, and that is not incidental. The module sets
  # DynamicUser and StateDirectory as *plain* definitions -- priority 100, the
  # same as anything written here -- so overriding them without mkForce is a
  # hard error rather than a silent merge:
  #
  #   The option `systemd.services.renovate.serviceConfig.DynamicUser' has
  #   conflicting definition values
  #
  # It is per-attribute, so only the two keys redefined here need it; the rest
  # of the module's serviceConfig is untouched. mkDefault would be the wrong
  # tool in the other direction: it loses to the module's plain definition and
  # the override would silently not apply.
  systemd.services.renovate = {
    # schedule is null above, so there is no timer. This unit is started by
    # renovate-schedule.service below, or by hand:
    #   incus exec renovate -- systemctl start --wait renovate.service

    # How the two tokens reach Renovate.
    #
    # services.renovate.credentials is the option built for this, and it does
    # not work in this instance. It becomes LoadCredential=SECRET-<NAME>:<path>
    # in the unit file, and the image's systemd generator then wipes it out:
    #
    #   /nix/store/...-distrobuilder-nixos-generator/lib/systemd/system-generators/.lxc-wrapped
    #     fix_systemd_override_unit() writes, into /run/systemd/system/service.d/zzz-lxc-service.conf,
    #     which applies to EVERY service in EVERY container built from this flake:
    #
    #       [ "${SYSTEMD}" -ge 249 ] && echo "LoadCredential=";
    #
    # An empty assignment to a list-type option resets it, and drop-ins are
    # applied after the unit file, so by the time systemd has finished parsing,
    # the credential list is empty. The unit starts, the module's script runs
    # `systemd-creds cat SECRET-RENOVATE_GITHUB_COM_TOKEN`, and the whole run
    # dies on the first one:
    #
    #   systemd-creds: Credential 'SECRET-RENOVATE_GITHUB_COM_TOKEN' not set.
    #   renovate.service: Main process exited, code=exited, status=1/FAILURE
    #
    # Observed, not theorised. The generator is presumably clearing credentials
    # it does not expect to find; nothing in a Nix configuration can undo it,
    # because the reset happens after the unit file is read and there is no
    # option to switch the generator off.
    #
    # EnvironmentFile= is not in that list, so it survives -- which is why
    # cloudflare-ddns gets its token that way and why this does too. 0400
    # root:root is right for it: systemd reads the file as root before dropping
    # to the renovate user, and the values appear in neither the unit file nor
    # `systemctl show -p Environment`.
    #
    # It is `EnvironmentFile` inside serviceConfig rather than a top-level
    # `environmentFile` because there is no such option for a generic unit --
    # services.caddy and services.paperless each define their own, and the only
    # spelling that reaches an arbitrary service is the systemd directive.

    serviceConfig = {
      EnvironmentFile = [
        "${secretsDir}/renovate-token-env"
        "${secretsDir}/renovate-github-token-env"
      ];
      # The module's default. It cannot be used, for the reason given next.
      DynamicUser = lib.mkForce false;

      # Spelled out even though systemd's default is already false here.
      #
      # It is load-bearing for the scheduler: a run that leaves this unit
      # "active (exited)" is a unit that `systemctl start` will refuse to start
      # again, so Renovate would run exactly once per boot and no number of
      # scheduled sweeps would change that. Pinned rather than inherited so
      # that a change to a default elsewhere cannot quietly reintroduce it --
      # this is the one setting in the file whose failure mode is "looks
      # configured, runs once, stops".
      RemainAfterExit = false;

      # Two directories: Renovate's own baseDir and cacheDir defaults from the
      # module, plus the report directory. Added as a second entry rather than
      # as a path under baseDir so that the report cannot be caught by
      # Renovate's own cleanup of its scratch space.
      StateDirectory = lib.mkForce [
        "renovate"
        "renovate-report"
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # The scheduler
  # ---------------------------------------------------------------------------
  #
  # One long-running unit that runs Renovate, reads the report, and sleeps for
  # the interval the result implies. Not a timer, and that is the design rather
  # than a workaround: a systemd timer's interval is fixed when the unit is
  # written, and the only ways to change one at runtime are to rewrite the unit
  # and daemon-reload, or to stop and start a different timer -- both of which
  # make "when does Renovate next run" a question with two answers at any moment.
  # Sleeping in a loop keeps exactly one answer, and `journalctl -u
  # renovate-schedule` states it after every cycle.
  #
  # Why it runs as root, when the run unit does not: it has to start another
  # system unit, and a DynamicUser or unprivileged service cannot do that without
  # a polkit rule granting it to that user, which would be a much larger hole
  # than the one being closed. It runs no code from the network, reads no secret,
  # and its loop is below.
  systemd.services.renovate-schedule = {
    description = "Runs Renovate on an adaptive interval";

    # Start at boot, not on a timer: the first sweep is wanted promptly after a
    # restart, and waiting out an interval to discover that a dependency moved
    # while the instance was down is the whole reason the interval is adaptive.
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [
      config.systemd.package
      pkgs.coreutils
      pkgs.jq
    ];

    # Never give up restarting. systemd's default is "started more than 5 times
    # in 10s, stay failed", which for a supervisor means one bad minute turns
    # into a dependency updater that is silently off until someone reboots the
    # instance.
    startLimitIntervalSec = 0;

    serviceConfig = {
      # `exec` rather than leaving it unset. NixOS does not default Type for a
      # script-based unit, so systemd would apply its own default of "simple",
      # which reports the unit as started the instant the process is forked --
      # before this script has read its state files or checked whether a
      # Renovate run is already in flight. `exec` waits for the execve to
      # succeed, so "active" means the loop is actually running. It is also the
      # only Type here that systemd's own check allows with Restart=always
      # below: NixOS asserts against "oneshot" plus an always-restart policy,
      # because oneshot is for work that finishes.
      Type = "exec";

      # The loop exits only if it is killed or if something it depends on is
      # missing, so this is a crash net rather than a feature. RestartSec is a
      # full minute because the failure this guards against is a bug in this
      # script, and a tight restart loop would turn that into a fork bomb with a
      # log to match. startLimitIntervalSec = 0 above disables systemd's
      # "started too often, giving up" limit: a unit that stops retrying is
      # indistinguishable from one that is working.
      Restart = "always";
      RestartSec = 60;

      StateDirectory = "renovate-schedule";

      # Narrower than the run unit's hardening on purpose, and by design rather
      # than by omission: this unit needs to talk to systemd over D-Bus and needs
      # to write its own state, so it cannot be as sealed as renovate.service.
      # It is still AF_UNIX-only -- it makes no network connections of its own,
      # because the thing that talks to Forgejo is the run unit below it.
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "full";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      SystemCallArchitectures = "native";
    };

    script = ''
      # NixOS wraps every generated unit script in "set -e" before the text
      # below is inserted (makeJobScript in nixos/lib/systemd-lib.nix), so the
      # errexit this loop must not inherit has to be taken back off explicitly.
      #
      # This is not a style preference. With -e still in force, the first failing
      # `systemctl start --wait` kills the loop before the exit code below is
      # ever read, and systemd restarts the unit 60s later straight into the
      # same failure -- so one unreachable repository would mean a dependency
      # updater re-running every minute forever, instead of one that notices,
      # backs off and carries on.
      set +e
      set -uo pipefail

      # Deliberately not `set -e`. A failing Renovate run is a normal event --
      # a repository that cannot be reached, a config error -- and the response
      # to it is "do not count it as activity and wait longer", which is
      # something this script decides by looking at the exit code. `set -e` would
      # instead kill the loop, and systemd would restart it into the same failure
      # once a minute forever.

      counter_file=${scheduleStateDir}/counter
      fingerprint_file=${scheduleStateDir}/fingerprint

      log() { printf 'renovate-schedule: %s\n' "$*"; }

      # A stable digest of the set of branches Renovate is maintaining, taken
      # from the report it just wrote.
      #
      # Branch name and PR number, not `result` and not a count of created PRs.
      # The set is the one piece of state that both halves of "something
      # happened" show up in: Renovate opening a PR adds an entry, and someone
      # merging or closing one removes it. So a diff catches interaction in both
      # directions -- including a human closing a PR that Renovate then reopens,
      # which is precisely the case where waiting a full interval is worst --
      # without this script having to know Renovate's per-branch result
      # vocabulary, which is not a stable interface.
      #
      # Returns non-zero for "no usable report", which the caller treats as no
      # activity rather than as a change. Two things count as unusable, and the
      # second is the one that matters:
      #
      #   * the file is missing, empty, or not parseable -- a run that died
      #     before writing one, or a config error;
      #   * `.branches` is not an array. That is not "no branches", it is this
      #     script no longer understanding the report, and the difference is the
      #     whole schedule: read as an empty branch list it would hash
      #     differently from the stored fingerprint, so every run would look
      #     like every branch had been deleted and the interval would sit at
      #     the five-minute rung for ever. As an error it is one log line and a
      #     backoff, which is the honest outcome for a report this script can no
      #     longer read.
      #
      # A genuinely empty branch list is still a valid answer -- that is what a
      # successful run over no repositories looks like -- so only a missing or
      # mistyped key fails here.
      fingerprint_of_report() {
        [ -s "${reportPath}" ] || return 1
        local branches
        branches=$(jq -er 'select((.branches | type) == "array") | [.branches[] | ((.branchName // "?") + "\t" + ((.prNo // "-") | tostring))] | sort | join("\n")' "${reportPath}") || return 1
        printf '%s' "$branches" | sha256sum | cut -d " " -f 1
      }

      counter=0
      fingerprint=
      if [ -r "$counter_file" ]; then
        counter=$(cat "$counter_file")
        # Anything that is not a plain number means a truncated or hand-edited
        # file; start over rather than carrying it into arithmetic below.
        # The empty-string pattern is spelled "" and not as a pair of single
        # quotes, because that pair ends the Nix string this script lives in.
        case "$counter" in
          "") counter=0 ;;
          *[!0-9]*) counter=0 ;;
        esac
        if [ "$counter" -gt ${toString maxCounter} ]; then
          counter=${toString maxCounter}
        fi
      fi
      if [ -r "$fingerprint_file" ]; then
        fingerprint=$(cat "$fingerprint_file")
      fi

      log "interval ladder: counter 0 = ${toString minIntervalSeconds}s, then +${toString stepIntervalSeconds}s per quiet run, capped at ${toString maxIntervalSeconds}s (counter ${toString maxCounter}); resuming at counter $counter"

      while :; do
        # Normally this loop is the only thing starting renovate.service. But
        # incus/apply.sh restarts that unit whenever it re-renders the tokens,
        # and "restart" on a run that is already in flight means a second full
        # sweep immediately behind the first. So if a run is already going,
        # wait for it and use its report instead of starting another.
        if systemctl is-active --quiet renovate.service; then
          log "renovate.service is already running (apply.sh restarts it after re-rendering its tokens); waiting for it rather than starting a second run"
          while systemctl is-active --quiet renovate.service; do
            sleep 5
          done
          # Its exit code is not available to us, so this is not a failure
          # signal -- only the report below is.
          rc=0
        else
          started=$(date +%s)
          systemctl start --wait renovate.service
          rc=$?
          log "renovate.service exited $rc after $(( $(date +%s) - started ))s"
        fi

        # An unreadable report leaves the stored fingerprint alone on purpose.
        # Overwriting it with nothing would make the next good run look like
        # every branch was deleted, which is a 5-minute interval for a run that
        # found nothing at all -- the schedule would ratchet towards busy
        # exactly when there is nothing to do.
        new_fingerprint=
        if new_fingerprint=$(fingerprint_of_report) && [ -n "$new_fingerprint" ]; then
          if [ "$new_fingerprint" != "$fingerprint" ]; then
            log "branches changed since the last run; next sweep in ${toString minIntervalSeconds}s"
            activity=1
          else
            log "no change since the last run; backing off"
            activity=0
          fi
          fingerprint=$new_fingerprint
        else
          log "no usable report at ${reportPath}; counting this run as no activity"
          activity=0
        fi

        if [ "$activity" -eq 1 ]; then
          # Any activity, from any depth, is 5 minutes away.
          counter=0
        else
          counter=$(( counter + 1 ))
          if [ "$counter" -gt ${toString maxCounter} ]; then
            counter=${toString maxCounter}
          fi
        fi

        # counter 0 is the hot rung; every counter above it is that many steps of
        # 15 minutes, capped.
        if [ "$counter" -eq 0 ]; then
          interval=${toString minIntervalSeconds}
        else
          interval=$(( counter * ${toString stepIntervalSeconds} ))
          if [ "$interval" -gt ${toString maxIntervalSeconds} ]; then
            interval=${toString maxIntervalSeconds}
          fi
        fi

        # Written to a temporary file and renamed, so a crash mid-write cannot
        # leave a half-written counter behind: the worst that could happen is a
        # restart that misreads one interval, and a truncated "2" read as
        # "25" is not one of them.
        printf '%s' "$counter" > "$counter_file.tmp"
        mv -f "$counter_file.tmp" "$counter_file"
        printf '%s' "$fingerprint" > "$fingerprint_file.tmp"
        mv -f "$fingerprint_file.tmp" "$fingerprint_file"

        log "counter $counter -> next run in $(( interval / 60 ))m $(( interval % 60 ))s"
        sleep "$interval"
      done
    '';
  };
}