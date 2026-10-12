# NixOS system for the Incus instance "minecraft".
#
# A Paper server run straight from a jar by a systemd unit. Replaces the k3s
# deployment in apps/minecraft/ (itzg's `minecraft-server` Helm chart plus
# mc-router in front of it), which was the same three things: a Paper jar, three
# plugin jars fetched from Hangar, and a JVM.
#
# ---------------------------------------------------------------------------
# Why not services.minecraft-server
# ---------------------------------------------------------------------------
#
# It is the obvious first reach for this and it does not fit. Evaluated against
# the nixpkgs this flake pins, the module's entire option set is:
#
#   dataDir  declarative  enable  eula  jvmOpts  openFirewall  package
#   serverProperties  whitelist
#
# So there is no `serverType`, no `version`, and no `motd`/`ops`/`difficulty`
# outside server.properties. Two of those are not options in any module and one
# is a hard blocker:
#
#   * `package` defaults to the vanilla Mojang server, and the deployment being
#     ported is Paper. nixpkgs has no Paper server package here at all --
#     `paperminecraft` is absent from this pin, and it is a client package in
#     any case. A vanilla server cannot load Portalis or WorldEdit, and Paper is
#     what the plugins are compiled against.
#
#   * `ops` is not a server.properties key. It is the contents of ops.json, i.e.
#     server state, and this file would be reaching into the data volume to
#     generate it anyway.
#
# The module also downloads the server jar itself on first boot from Mojang's
# manifests, which is the vanilla-only path. So the jar is fetched here instead,
# and the rest is an ordinary unit. That is also closer to what it replaces: the
# chart did not use a NixOS module either, it used a container image that did
# the same fetch at runtime.
{ lib, pkgs, ... }:

let
  # -------------------------------------------------------------------------
  # The Paper version to run
  # -------------------------------------------------------------------------
  #
  # Pinned, and this is the one place where "faithful to the old deployment"
  # would have been the wrong call. The chart set `version: LATEST`, and itzg's
  # image resolves that at container start -- so the old deployment tracked
  # upstream by default. Resolving LATEST here, today, would install Minecraft
  # 26.3, which:
  #
  #   * requires Java 25 (Paper's own API reports java.version.minimum 25 for
  #     26.x), not the Java 21 this flake's nixpkgs ships as its default server
  #     JRE, and
  #   * drags the world across a major version boundary on first boot. Paper
  #     upgrades a world forward and it usually works, but "usually" is not a
  #     property to apply to somebody's two-year build by unattended timer.
  #
  # 1.21.11 is the newest release in the 1.21 line: still Java 21, a routine
  # forward step for any 1.20/1.21 world, and the line the three plugin jars
  # below were resolved against.
  #
  # If the world turns out to be NEWER than this -- check before loading the k3s
  # data, because Paper will not go backwards -- change this one line, delete
  # server.jar and .paper-build on the volume, and restart. See README.md.
  minecraftVersion = "1.21.11";

  # Paper's current API. The v2 API this used to be written against
  # (api.papermc.io/v2) is gone:
  #
  #   HTTP 410 {"ok":false,"error":"sunset",
  #             "message":"This API version has been sunset ..."}
  #
  # so a fetch written against v2 fails on first boot with a 410 and no other
  # clue. v3 is fill.papermc.io, and the jar is served from a separate
  # fill-data host.
  paperApi = "https://fill.papermc.io/v3/projects/paper";

  # -------------------------------------------------------------------------
  # Plugin jars, verbatim from apps/minecraft/helm-release.yaml
  # -------------------------------------------------------------------------
  #
  # Same three URLs, same order, same versions. These are the plugin *configs*
  # that migrate with the world; the jars themselves are re-downloaded rather
  # than copied, so a corrupt jar in the PVC cannot be inherited.
  pluginUrls = [
    "https://hangarcdn.papermc.io/plugins/KingTheGuy/Portalis/versions/1.0/PAPER/portalis-1.0.jar"
    "https://hangarcdn.papermc.io/plugins/EngineHub/WorldEdit/versions/7.3.17/PAPER/worldedit-bukkit-7.3.17.jar"
    "https://hangarcdn.papermc.io/plugins/kennytv/WorldEditSUI/versions/1.7.4/PAPER/WorldEditSUI-1.7.4.jar"
  ];

  # -------------------------------------------------------------------------
  # JVM
  # -------------------------------------------------------------------------
  #
  # openjdk21, because 1.21.11 requires 21 and because that is what this
  # nixpkgs ships. The container memory limit in ./incus.nix is what makes -Xmx2G
  # safe; the two are one decision and are not independent.
  jvmOpts = lib.concatStringsSep " " [
    "-Xms1G"
    "-Xmx2G"
    # Paper's own recommended G1GC set, minus the ones that are about
    # benchmarking noise rather than a homelab server.
    "-XX:+UseG1GC"
    "-XX:MaxGCPauseMillis=200"
    "-XX:+ParallelRefProcEnabled"
    "-XX:+DisableExplicitGC"
  ];

  # -------------------------------------------------------------------------
  # Whitelist and ops
  # -------------------------------------------------------------------------
  #
  # As name -> UUID, because whitelist.json and ops.json are keyed on the
  # player's UUID and a UUID is not optional. This was found by booting it, not
  # by reading it: the first version of this file wrote the two lists as arrays
  # of bare name strings, which is what the k3s chart held them as, and Paper
  # silently parsed both as EMPTY and then rewrote them to `[]` on startup --
  # destroying them. The symptom was a server running with `white-list=true` and
  # an empty whitelist, i.e. one nobody could join, plus no operators.
  #
  # The nixpkgs module this file does not use gets the same thing right, and its
  # option shape is the reason for the format below: `whitelist` there is an
  # attrsOf of a UUID-matching string, rendered as `{ name, uuid }` objects.
  #
  # These UUIDs come from Mojang's public profile API
  # (api.mojang.com/users/profiles/minecraft/<name>), which is the right source
  # precisely because this server runs online-mode=true: the UUID has to be the
  # one the account authenticates with, and for a premium account that is what
  # Mojang says it is. A cracked/offline player would need a different UUID and
  # could not be resolved this way at all.
  #
  # The rosters themselves are the chart's, verbatim, and they are a starting
  # point rather than the last word: once the k3s PVC is loaded these two files
  # come across with it and stop being written here at all (see the repair rule
  # in minecraft-config.service). Whoever added an operator in-game since has
  # the authoritative list.
  whitelist = {
    SakulFlee = "e1f94c32e1a1450a8e065ab0d0209c29";
    jendrik12799 = "04678318bc4c4c43be95cd6f7446136b";
    Lennart116002 = "9da0c24e55ad4005bbcad5443585b4cf";
    Fisch246 = "23aa287262ba4727bb34fa895ac95170";
    DarkRune2214 = "8e85b2a7fbe14b54a9c7c6589e21578f";
    _MinaChan_ = "455539b1b9824fe9966ba37f6a3436ea";
    Froggy189 = "2c690aa62cc34e68b0ac8e245d297c6f";
  };

  ops = {
    SakulFlee = "e1f94c32e1a1450a8e065ab0d0209c29";
    jendrik12799 = "04678318bc4c4c43be95cd6f7446136b";
  };

  # Rendered here rather than assembled in the unit's shell, so the JSON is a
  # build product and cannot be malformed by quoting. Same approach the nixpkgs
  # module takes with pkgs.writeText.
  #
  # `level: 4` is the vanilla operator level and `bypassesPlayerLimit: false`
  # is what Paper writes for an ordinary op; both are part of the ops.json entry
  # shape, and omitting them is not the same as leaving them at a default.
  whitelistJson = pkgs.writeText "whitelist.json" (
    builtins.toJSON (lib.mapAttrsToList (name: uuid: { inherit name uuid; }) whitelist)
  );

  opsJson = pkgs.writeText "ops.json" (
    builtins.toJSON (
      lib.mapAttrsToList (name: uuid: {
        inherit name uuid;
        level = 4;
        bypassesPlayerLimit = false;
      }) ops
    )
  );

  # Where the backups go, and how many to keep. 14 archives is two weeks of
  # dailies, which is the window in which somebody notices a bad world edit.
  #
  # Pruning here does NOT delete anything on the peer. A sendonly folder never
  # applies a remote deletion, so an archive pruned locally stays on Dendra
  # forever. That is a deliberate property to have in a backup, and it is also
  # why the count can be this small without being the whole history.
  keepArchives = 14;
in
{
  networking.hostName = "minecraft";

  # Same posture as every other instance, and here it is load-bearing rather
  # than tidy: the 25565 forward in ./incus.nix DNATs into this container, and a
  # guest firewall would be re-filtering traffic the host has already decided to
  # admit. The forward IS the gate, exactly as Caddy's VPN gate is for
  # paperless. (The nixpkgs module's `openFirewall` option would open the port
  # here instead; it is moot with the firewall disabled, which is why this file
  # does not set it.)
  networking.firewall.enable = false;

  # The router, same as the other instances. Not optional: the fetch unit below
  # resolves fill.papermc.io through this.
  networking.nameservers = [ "192.168.178.1" ];

  # Not exposed: Incus reaches the instance via exec, and nothing forwards 22.
  services.openssh.enable = false;

  # curl, to reach the server's own log over the API at verification time, and
  # to talk to the paperless/syncthing instances by hand from in here.
  environment.systemPackages = [ pkgs.curl ];

  # -------------------------------------------------------------------------
  # The service account
  # -------------------------------------------------------------------------
  #
  # uid/gid 988, pinned. The number itself matters for one reason: the data load
  # from k3s has to land owned by a known uid, because the k3s pod's files are
  # owned by whatever uid its image chose and copying them in preserves that.
  # Deciding the target number here means the load is a chown to 988 rather than
  # a question about what NixOS happened to allocate. 987 is paperless; 996 is
  # qbittorrent.
  #
  # A home directory is deliberately not created: there is nothing to put in it,
  # and `install -d` below owns the only directory the service writes to.
  users.users.minecraft = {
    isSystemUser = true;
    group = "minecraft";
    uid = 988;
    description = "Minecraft Paper server";
  };
  users.groups.minecraft.gid = 988;

  # -------------------------------------------------------------------------
  # Owning the volume
  # -------------------------------------------------------------------------
  #
  # Incus creates a disk device's mount point as 0711 root:root, which is
  # correct for its purposes and useless to a service that has to write there.
  # This is the same fix forgejo and paperless needed for the same reason, and
  # `install -d` rather than a tmpfiles rule for the reason paperless gives:
  # tmpfiles runs independently of (and, in the general case, before) the rest
  # of activation, whereas this is ordered explicitly ahead of everything that
  # writes to the volume.
  #
  # install -d is idempotent and leaves the contents alone -- it adjusts only the
  # directory itself, never recurses, so this does not walk a world.
  systemd.services.minecraft-dirs = {
    description = "Create and own the data and backup volume mount points";
    wantedBy = [ "multi-user.target" ];
    before = [
      "minecraft-fetch.service"
      "minecraft-config.service"
      "minecraft.service"
    ];
    after = [ "local-fs.target" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe' pkgs.coreutils "install"
        + " -d -m 0755 -o minecraft -g minecraft"
        + " /var/lib/minecraft /var/lib/minecraft/backups /var/lib/minecraft/plugins";
    };
  };

  # -------------------------------------------------------------------------
  # Fetching the server jar and the plugins
  # -------------------------------------------------------------------------
  #
  # Idempotent in the way that matters: it resolves the newest STABLE build for
  # the pinned version, and then does nothing at all if that exact build is
  # already on the volume. So a restart never re-downloads 50MB, and a change
  # to minecraftVersion does fetch the new one.
  #
  # The resolved version/build pair is recorded in .paper-build, which makes the
  # running server identifiable from the filesystem alone -- and ends up inside
  # every backup archive, so an archive says what produced it.
  #
  # The download is checksum-verified against the sha256 the API publishes for
  # that build. Not ceremony: the URL is a content-addressed object store path,
  # so the check is free and it turns a truncated or proxied download into a
  # failed unit instead of a server that will not start.
  systemd.services.minecraft-fetch = {
    description = "Fetch the Paper server jar and the plugin jars";
    wantedBy = [ "multi-user.target" ];
    before = [ "minecraft.service" ];
    after = [ "network-online.target" "minecraft-dirs.service" ];
    wants = [ "network-online.target" ];
    requires = [ "minecraft-dirs.service" ];
    path = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "minecraft";
      Group = "minecraft";
      WorkingDirectory = "/var/lib/minecraft";
    };
    script = ''
      set -euo pipefail

      mc_version=${lib.toString minecraftVersion}

      fetch_plugin() {
        local url="$1" name
        name="$(basename "$url")"
        if [ -f "plugins/$name" ]; then
          echo "plugin $name already present"
          return 0
        fi
        echo "fetching plugin $name"
        curl -fsSL --retry 3 --retry-delay 2 -o "plugins/$name.tmp" "$url"
        mv "plugins/$name.tmp" "plugins/$name"
      }

      # Newest STABLE build for the pinned version. The v3 builds array is
      # newest-first, so [0] after filtering on channel is the one to take;
      # selecting on channel rather than trusting the order is what keeps a
      # nightly or a release candidate out of a server that nobody is watching.
      # The API URL below is written in braces rather than bare, and that is not
      # cosmetic. A bare $paperApi is a shell variable as far as Nix is
      # concerned -- it interpolates nothing and lands in the script verbatim --
      # so it would arrive here as an unset name, and `set -u` would kill the
      # unit with "paperApi: unbound variable" before a single byte was fetched.
      # $mc_version on the next line IS a shell variable, assigned a few lines
      # above, and must stay bare for exactly that reason.
      builds=$(curl -fsSL --retry 3 --retry-delay 2 \
        "${paperApi}/versions/$mc_version/builds")

      build=$(jq -r '
        [ .[] | select(.channel == "STABLE") ]
        | first
        | .id // empty
      ' <<<"$builds")

      if [ -z "$build" ]; then
        echo "no STABLE Paper build for $mc_version; refusing to guess" >&2
        exit 1
      fi

      url=$(jq -r --argjson b "$build" '
        .[] | select(.id == $b) | .downloads["server:default"].url
      ' <<<"$builds")
      sha=$(jq -r --argjson b "$build" '
        .[] | select(.id == $b) | .downloads["server:default"].checksums.sha256
      ' <<<"$builds")

      if [ -f server.jar ] && [ -f .paper-build ] \
         && [ "$(cat .paper-build)" = "$mc_version/$build" ]; then
        echo "Paper $mc_version build $build already present"
      else
        echo "fetching Paper $mc_version build $build"
        curl -fsSL --retry 3 --retry-delay 2 -o server.jar.tmp "$url"
        echo "$sha  server.jar.tmp" | sha256sum -c -
        mv server.jar.tmp server.jar
        printf '%s/%s\n' "$mc_version" "$build" > .paper-build
      fi

      for plugin_url in ${lib.escapeShellArgs pluginUrls}; do
        fetch_plugin "$plugin_url"
      done
    '';
  };

  # -------------------------------------------------------------------------
  # First-run configuration
  # -------------------------------------------------------------------------
  #
  # Everything here is "only if absent". That is the whole design of this unit,
  # and it is what makes the data load safe: the k3s PVC is the authority for
  # this server's actual configuration, not the chart values it was created
  # with. Six weeks of play have almost certainly drifted from them -- level
  # seed, pvp, spawn-npcs, the world border, the operator list, whatever
  # somebody set in-game.
  #
  # So a migrated volume keeps every one of those files untouched, and this unit
  # only fills in what a brand new volume is missing. The values below are the
  # chart's, and they exist to make a fresh volume behave like the k3s one did.
  # Once the world is migrated this unit becomes a no-op, which is the intended
  # end state rather than a leftover.
  #
  # The marker and the ignore file are the exception: they are about the
  # replication contract rather than about this server, and they are written
  # unconditionally so the hub never sits with a stopped folder.
  systemd.services.minecraft-config = {
    description = "Lay down first-run configuration, and the Syncthing folder marker";
    wantedBy = [ "multi-user.target" ];
    before = [ "minecraft.service" ];
    after = [ "minecraft-dirs.service" ];
    requires = [ "minecraft-dirs.service" ];
    path = [
      pkgs.jq
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "minecraft";
      Group = "minecraft";
      WorkingDirectory = "/var/lib/minecraft";
    };
    script = ''
      set -euo pipefail

      # -- the EULA ------------------------------------------------------------
      #
      # Written unconditionally and idempotently, because a server that cannot
      # start is a worse first run than one that agreed to the EULA on the
      # operator's behalf -- and the chart set `eula: 'TRUE'` as well, so this
      # is not a new decision, it is the old one moved here.
      printf 'eula=true\n' > eula.txt

      # -- server.properties ----------------------------------------------------
      #
      # Chart parity, from apps/minecraft/helm-release.yaml. Everything not
      # mentioned there is left at Paper's default by omission, on purpose: an
      # exhaustive file here would be a second place to be wrong.
      if [ ! -f server.properties ]; then
        cat > server.properties <<'PROPS'
      #Minecraft server properties, generated by nixos/hosts/minecraft
      difficulty=normal
      gamemode=survival
      level-name=world
      max-players=20
      motd=Conduit Network @ SakulFlee
      online-mode=true
      server-port=25565
      simulation-distance=10
      spawn-protection=16
      sync-chunk-writes=true
      view-distance=10
      white-list=true
      PROPS
        echo "wrote a fresh server.properties from the k3s chart's values"
      else
        echo "server.properties exists; leaving the running server's own copy alone"
      fi

      # -- whitelist and ops ----------------------------------------------------
      #
      # Written when MISSING **or unusable**, and that second condition is the
      # whole subtlety. "Missing" alone was the first version's rule, and it is
      # not enough: Paper owns these two files at runtime and rewrites them when
      # it loads a list it could not parse, so a malformed file does not stay
      # malformed -- it gets replaced with `[]`, which then counts as present and
      # would never be repaired. That is precisely the state this unit created on
      # its first run, and `[]` is not a whitelist anybody wants on a server with
      # `white-list=true`.
      #
      # So: repair an absent or empty list, preserve a populated one. That gives
      # a fresh volume a working roster, gives a migrated volume the live
      # server's own roster untouched, and repairs the destroy-on-first-boot case
      # -- without ever clobbering an operator somebody added in-game, which is
      # the thing a blanket "always overwrite" would throw away.
      #
      # `ops` is NOT a server.properties key and never was: it is this file,
      # which is the concrete reason this could not have been an option.
      if jq -e 'type == "array" and length > 0' whitelist.json >/dev/null 2>&1; then
        echo "whitelist.json is populated; leaving it alone"
      else
        install -m 0644 ${whitelistJson} whitelist.json
        echo "wrote whitelist.json ($(jq -r 'length' whitelist.json) players)"
      fi

      if jq -e 'type == "array" and length > 0' ops.json >/dev/null 2>&1; then
        echo "ops.json is populated; leaving it alone"
      else
        install -m 0644 ${opsJson} ops.json
        echo "wrote ops.json ($(jq -r 'length' ops.json) operators)"
      fi

      # -- the replication marker ----------------------------------------------
      #
      # The Syncthing hub mounts minecraft-backups READ-ONLY (see
      # ../syncthing/incus.nix), so it can never write the marker Syncthing
      # requires before it will scan a folder -- the producer has to. Without
      # it the folder sits "stopped" in the WebUI and nothing is ever
      # replicated. This is step 5 of the contract in ../syncthing/NOTES.md, and
      # the only part of that contract that is this instance's job.
      #
      # A directory, not a file, which is what paperless does and what
      # Syncthing has historically created. The systemd.tmpfiles rule at the
      # bottom of this file owns 988 numerically; here the directory is simply
      # created by the account that owns it, which is the same uid by
      # construction rather than by agreement.
      #
      # Written unconditionally on purpose: unlike the server config above, a
      # marker that has gone missing is a fault to repair rather than a
      # preference to preserve.
      mkdir -p backups/.stfolder

      # -- the ignore file ------------------------------------------------------
      #
      # Also replication, not server config. The backup unit writes each archive
      # to a .tmp name and renames it into place, so a partially written archive
      # is never visible under its final name -- but without this, the in-flight
      # .tmp file is itself a file in a folder the hub watches with inotify, and
      # the hub would hash and ship a growing tarball.
      #
      # Ignores propagate: .stignore is part of the folder, so the hub honours
      # this too, which is the only reason writing it here is sufficient.
      printf '*.tmp\n' > backups/.stignore
    '';
  };

  # -------------------------------------------------------------------------
  # The server
  # -------------------------------------------------------------------------
  #
  # `nogui` because there is no console to speak of: systemd gives the process no
  # TTY and Paper would otherwise sit waiting on stdin.
  systemd.services.minecraft = {
    description = "Minecraft Paper server";
    documentation = [ "https://docs.papermc.io/paper/" ];
    wantedBy = [ "multi-user.target" ];
    after = [
      "minecraft-dirs.service"
      "minecraft-fetch.service"
      "minecraft-config.service"
    ];
    # Not wants: if the fetch or the config failed there is no jar or no eula,
    # and starting the server anyway turns a clear unit failure into a crash
    # loop with a stack trace instead of the reason.
    requires = [
      "minecraft-dirs.service"
      "minecraft-fetch.service"
      "minecraft-config.service"
    ];
    serviceConfig = {
      Type = "simple";
      User = "minecraft";
      Group = "minecraft";
      WorkingDirectory = "/var/lib/minecraft";
      ExecStart = lib.getExe' pkgs.jre "java"
        + " ${jvmOpts} -jar server.jar nogui";

      # on-failure, not always: a `stop` from the console, or from the backup
      # unit below, is a deliberate end and must not be undone by a restart
      # policy. Crashes do get restarted.
      Restart = "on-failure";
      RestartSec = "15s";

      # Paper flushes and saves the world on SIGTERM, and how long that takes
      # scales with the world. systemd's 90s default is a hard kill in the middle
      # of a save for a large world, and a save killed halfway is exactly the
      # corruption the backup unit exists to prevent.
      KillSignal = "SIGTERM";
      TimeoutStopSec = "300";

      # Paper exits 0 on a clean stop. 143 is SIGTERM, which is what systemd
      # records if the stop above timed out -- counted as success so a slow save
      # does not also report a failure.
      SuccessExitStatus = "0 143";
    };
  };

  # -------------------------------------------------------------------------
  # Backups
  # -------------------------------------------------------------------------
  #
  # One archive a day of the whole data directory, and only the archives are
  # replicated (see ./incus.nix). The tar covers everything under
  # /var/lib/minecraft except the backups volume itself, so it carries the
  # world, the plugin configuration, the operator and whitelist lists and the
  # server properties together -- which is the unit that is actually restorable.
  # An archive of `world/` alone would not be.
  #
  # The server is STOPPED around the tar, and that is the interesting decision.
  # Copying a running world is the usual shortcut and it is the one that
  # produces backups which are subtly wrong: Paper writes region files in place,
  # so a tar that reads one mid-write captures a half-updated chunk, and the
  # failure surfaces weeks later as "that area of the map is gone". The stop
  # costs a few seconds once a day at 04:00 on a server that sleeps anyway, and
  # the alternative costs correctness.
  #
  # save-off/save-all would avoid the downtime, but it needs a channel into the
  # server console (RCON with a generated password, or a socket unit to write
  # to stdin) and it has its own failure mode: if the process dies between
  # save-off and save-on, the world is left unflushed and unsaveable. The stop
  # has no such window.
  systemd.services.minecraft-backup = {
    description = "Archive the Minecraft data directory";

    # No ordering against minecraft.service in either direction, deliberately.
    # This unit has to be startable while the server is stopped -- that is the
    # whole point of the is-active check below -- so an After= on minecraft
    # would deadlock exactly that case, and a Before= would do the same to the
    # server's own boot.
    path = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnutar
      pkgs.systemd
    ];
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/minecraft";
    };

    # Inline script rather than a writeShellApplication derivation, like the
    # other units in this file: the unit's `path` above is the same mechanism,
    # and one style is easier to read than two.
    #
    # No User=, also deliberately: this stops and starts minecraft.service, so
    # it has to talk to systemd. That is root inside the container, which is
    # what every other instance's units already run as.
    script = ''
      set -euo pipefail

      data=/var/lib/minecraft
      backups=$data/backups
      stamp=$(date -u +%Y%m%dT%H%M%SZ)
      archive=minecraft-$stamp.tar.gz

      # If the server is up, stop it for the duration. If it is already down --
      # deliberately, or because it crashed -- the world on disk is quiescent
      # and there is nothing to stop: back it up as it is, and do NOT start a
      # server that somebody stopped on purpose.
      #
      # Stopping it this way also stops the three prep units, because
      # minecraft.service `Requires=` them and systemd propagates a stop down a
      # Requires edge. That is not a problem, it is a bonus: the `start` below
      # pulls them back in and re-runs them, and every one of them is
      # idempotent and offline (the fetch short-circuits on the .paper-build
      # marker rather than re-downloading 50MB). So the daily backup doubles as
      # a self-heal of the volume's layout. It is also why those three units
      # carry RemainAfterExit -- without it they would simply be re-run anyway.
      if systemctl is-active --quiet minecraft.service; then
        echo "stopping minecraft.service for a consistent archive"
        systemctl stop minecraft.service
        # EXIT, not a plain call at the end: a tar that fails, or a prune that
        # fails, must still put the server back. Without the trap a failed
        # backup takes the game down until somebody noticed.
        trap 'systemctl start minecraft.service' EXIT
      else
        echo "minecraft.service is not running; archiving the quiescent world"
      fi

      # Written to a .tmp name and renamed, because the hub watches this
      # directory with inotify: a .tar.gz that grows for two minutes is a file
      # it would try to hash and ship repeatedly. backups/.stignore excludes
      # *.tmp on every device, so only the finished archive is ever visible to
      # Syncthing. See minecraft-config.service.
      #
      # ./backups is excluded from the archive itself, and that is not tidiness:
      # without it the archive would contain the previous fourteen archives,
      # each of which would contain the fourteen before it, and the volume would
      # fill with an exponential pile-up on the second run.
      tar -C "$data" -czf "$backups/$archive.tmp" \
        --exclude=./backups \
        --exclude=./cache \
        --exclude=./logs \
        --exclude='*.lock' \
        .

      mv "$backups/$archive.tmp" "$backups/$archive"
      echo "wrote $backups/$archive ($(du -h "$backups/$archive" | cut -f1))"

      # Local retention only. A sendonly folder never applies a remote deletion,
      # so nothing pruned here disappears from the peer.
      find "$backups" -maxdepth 1 -type f -name 'minecraft-*.tar.gz' \
        -mtime +${toString keepArchives} -print -delete

      exit 0
    '';
  };

  systemd.timers.minecraft-backup = {
    description = "Archive the Minecraft data directory daily";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 04:00, and deliberately not on the hour: the host's restic runs at :37
      # every hour and fifteen other instances reconcile on a fifteen minute
      # cycle, so the odd hour is where the quiet corners are.
      OnCalendar = "*-*-* 04:00:00";
      RandomizedDelaySec = "20m";

      # A container that was off at 04:00 still gets a backup when it comes
      # back, rather than silently skipping a day.
      Persistent = true;
      AccuracySec = "1m";
    };
  };

  # -------------------------------------------------------------------------
  # The replicated-folder marker
  # -------------------------------------------------------------------------
  #
  # Declared here as well as written by minecraft-config.service, and the reason
  # is ordering rather than redundancy: tmpfiles rules are sorted by path, so
  # this one is created before the units that write into the volume, and it
  # survives the volume being mounted empty. It is the same rule paperless
  # carries, in the same shape, for the same reason.
  #
  # `d` and not `f`, so a Syncthing folder works whether it expects a directory
  # or a file here.
  systemd.tmpfiles.rules = [
    "d /var/lib/minecraft/backups/.stfolder 0755 988 988 -"
  ];
}