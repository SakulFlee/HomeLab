{ config, lib, pkgs, ... }:

let
  # The single source of truth for which instances exist. Same file the flake
  # exposes as `incusInstances` and incus/apply.sh reads, so the units below can
  # never drift from what apply.sh would actually do.
  instances = import ../../../incus-instances.nix;
  instanceNames = lib.attrNames instances;

  # Per-instance Incus project, or "" for Incus's `default`. Same map apply.sh
  # reads, so the per-instance units and the timer-driven `--all` reconcile can
  # never disagree about which project an instance lives in -- and an instance
  # addressed in the wrong project is not found at all, with its volumes
  # reported missing because volumes are project-scoped.
  instanceProjects = import ../../../incus-instance-projects.nix;

  # "--project <p>" only when the instance has one, so the default case renders
  # the same command line it always did.
  projectArg =
    name:
    let
      p = instanceProjects.${name} or "";
    in
    if p == "" then "" else "--project ${p}";

  # The checkout, not a store path. incus/apply.sh and the instance specs live
  # here, and a path unit needs a real on-disk path to watch -- a store path is
  # immutable, so a unit watching one could never fire.
  repoDir = "/etc/nixos";
  flakeDir = "${repoDir}/nixos";
  applyScript = "${repoDir}/incus/apply.sh";

  # ---------------------------------------------------------------------
  # What each instance watches
  #
  # Scoped to the instance's own inputs, so a caddy rebuild is not triggered by
  # a forgejo edit. Deliberately so: an unnecessary rebuild costs a nix build
  # that returns immediately, but with a dozen instances the hourly auto-update
  # sweep turns "returns immediately" into a visible stall, and the point of
  # per-instance units is that they actually are per-instance.
  #
  # This is the complete closure of what the flake reads when building one
  # instance image:
  #
  #   flake.nix, flake.lock   inputs, and the mkInstance wrapper
  #   incus-instances.nix     the registry, which selects the spec
  #   hosts/<name>/           that instance's default.nix and incus.nix
  #   modules/                shared NixOS modules -- nothing imports these
  #                           today, but this is where the first shared module
  #                           will land, and missing it would be a stale image
  #                           nobody notices
  #   incus/apply.sh          the reconciler itself
  #
  # Not watched: hosts/homelab/, hardware/ and users/. Those are the *host*,
  # and the host does not appear in any instance's build closure. Rebuilding
  # every instance image because the host's NIC changed would be pure waste.
  #
  # Enumerated relative to the flake root, not relative to /etc/nixos, so the
  # lists are the same wherever the flake happens to be checked out -- which is
  # what makes this file evaluable off-server. The relative names are re-rooted
  # into the live checkout below.
  #
  # ../../../. is the flake root. Nix resolves a relative path literal against
  # the directory of the file it appears in, so from
  # nixos/hosts/homelab/services/ that is three levels up. "./." would enumerate
  # only this directory, and "../../." would silently stop at nixos/hosts.
  flakeRootDir = ../../../.;

  # Top-level files every instance build reads.
  sharedFiles = [
    "flake.nix"
    "flake.lock"
    "incus-instances.nix"
  ];

  # Subtrees, relative to the flake root, that feed every image.
  sharedTrees = [ "modules" ];

  # The apply tooling lives outside the flake (a flake may not read paths above
  # its own root), so it cannot be enumerated from here. It is one file today and
  # it is named below. Adding another needs a host rebuild to be watched.
  #
  # builtins.pathExists matters: PathModified= against a path that does not
  # exist makes the whole path unit fail to start, and incus/ is a new directory
  # that a host which has not pulled yet does not have.
  toolingNames = [ "apply.sh" ];
  toolingFiles = builtins.filter (f: builtins.pathExists "${repoDir}/incus/${f}") toolingNames;

  # builtins.readDir changed shape. It used to return
  #   { name = { type = "regular" | "directory" | "symlink"; }; }
  # and now returns the type string directly:
  #   { name = "regular" | "directory" | "symlink"; }
  # Observed on both 2.34.8 and 2.35.2, so handle both rather than shipping a
  # module that only evaluates on one of them.
  entryType = entry: if builtins.isAttrs entry then entry.type else entry;

  childrenOf = dir:
    let
      entries = builtins.readDir dir;
    in
    map (name: {
      name = name;
      isDir = entryType (builtins.getAttr name entries) == "directory";
      path = "${toString dir}/${name}";
    }) (builtins.attrNames entries);

  listFilesRel = dir:
    builtins.concatLists (
      map (c: if c.isDir then map (rel: "${c.name}/${rel}") (listFilesRel c.path) else [ c.name ])
        (childrenOf dir)
    );

  listDirsRel = dir:
    [ "" ] ++ builtins.concatLists (
      map (c: map (rel: if rel == "" then c.name else "${c.name}/${rel}") (listDirsRel c.path))
        (builtins.filter (c: c.isDir) (childrenOf dir))
    );

  # The subtrees this instance watches, filtered to those that exist. A missing
  # one degrades to "watches less" rather than failing the whole host eval.
  treesFor = name: builtins.filter (t: builtins.pathExists "${flakeRootDir}/${t}") (
    sharedTrees ++ [ "hosts/${name}" ]
  );

  filesIn = tree: map (rel: "${flakeDir}/${tree}/${rel}") (listFilesRel "${flakeRootDir}/${tree}");
  dirsIn = tree:
    map (rel: if rel == "" then "${flakeDir}/${tree}" else "${flakeDir}/${tree}/${rel}")
      (listDirsRel "${flakeRootDir}/${tree}");

  watchFilesFor = name:
    map (rel: "${flakeDir}/${rel}") sharedFiles
    ++ builtins.concatLists (map filesIn (treesFor name))
    ++ map (f: "${repoDir}/incus/${f}") toolingFiles;

  watchDirsFor = name:
    # flakeDir itself, so a new top-level file is still noticed. PathChanged on
    # a directory fires when an entry is added, removed or renamed -- never when
    # a file deeper down is merely edited -- so this costs nothing on a normal
    # commit and closes the gap for genuinely new inputs.
    [ flakeDir ]
    ++ builtins.concatLists (map (t: [ "${flakeDir}/${t}" ] ++ dirsIn t) (treesFor name))
    ++ lib.optional (builtins.pathExists "${repoDir}/incus") "${repoDir}/incus";

  unitName = name: "incus-apply-${name}";
in
{
  # ---------------------------------------------------------------------
  # Per-instance apply service
  #
  # Type=oneshot, so systemd treats a re-trigger while one is still running as
  # a no-op rather than queueing a second pass. Combined with the fingerprint
  # check inside apply.sh, running this on every change is cheap when nothing
  # changed and correct when something did.
  #
  # Not started at boot on purpose. Incus already restarts instances from their
  # imported images when incusd comes up, which is the entire benefit of
  # deploying images rather than building in place. Rebuilding on every boot
  # would add minutes of boot time for nothing.
  #
  # A failed run is retried, because most failures here are transient: incusd
  # still coming up, a pool not mounted yet, a store lock held by the host
  # rebuild that triggered this. Without it the unit sits in `failed` until the
  # next edit, and a redeploy that silently did not happen is the worst
  # possible outcome. The rate limit is what keeps that from becoming a hot
  # loop -- a genuinely broken config burns five builds over four minutes and
  # then stays failed, which is the behaviour we want.
  #
  # Restart= on a oneshot is only permitted as on-failure; systemd rejects
  # always and on-success for Type=oneshot.
  # ---------------------------------------------------------------------
  systemd.services =
    lib.mapAttrs'
      (name: _spec: {
        name = unitName name;
        value = {
          description = "Build the ${name} Incus image and reconcile the instance";

          after = [ "network-online.target" "incus.service" ];
          wants = [ "network-online.target" ];
          requires = [ "incus.service" ];

          # nix build of a container image plus a ~284MB import. The 90s default
          # would be killed mid-import, leaving a partial image in the pool.
          serviceConfig = {
            Type = "oneshot";
            WorkingDirectory = flakeDir;
            TimeoutStartSec = 3600;
            Restart = "on-failure";
            RestartSec = 60;
          };

          # startLimit* belong in [Unit], not [Service]. Setting them inside
          # serviceConfig renders them into [Service], where systemd rejects them:
          #   Unknown key 'StartLimitIntervalSec' in section [Service], ignoring
          # which is silently ignored -- so the retry policy was not in effect.
          startLimitIntervalSec = 2400;
          startLimitBurst = 5;

          # %p, not %n. %n is the failed unit's *full* name, so it already ends
          # in ".service" and "@%n.service" produced
          #   incus-apply-notify@incus-apply-caddy.service.service
          # which systemd refused to enqueue at all. %p is the prefix, so
          # "@%p.service" is the correct template instantiation -- and it also
          # satisfies the option's type, which requires a known unit suffix.
          onFailure = [ "incus-apply-notify@%p.service" ];

          # Only the binaries apply.sh actually shells out to. Notably
          # config.virtualisation.incus.package rather than a hardcoded
          # pkgs.incus, so this cannot end up driving the daemon with a
          # different client.
          path = [
            pkgs.bash
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.git
            pkgs.jq
            pkgs.nix
            config.virtualisation.incus.package
          ];

          # --project only where the instance declares one. apply.sh also reads the same
          # map per instance, so this is belt-and-braces for the single-instance
          # path; --all cannot take a single flag for a set spanning projects and
          # relies on that per-instance lookup instead.
          script = "${pkgs.bash}/bin/bash ${applyScript} ${projectArg name} ${name}";
        };
      })
      instances
    // {
      # -----------------------------------------------------------
      # Failure notification
      #
      # A template, so the attribute name ends in @ and NixOS renders
      # incus-apply-notify@.service. Declared as "incus-apply-notify" it produced
      # a plain incus-apply-notify.service, which cannot be instantiated, and
      #   Failed to enqueue OnFailure=... job, ignoring:
      #   Unit incus-apply-notify@incus-apply-caddy.service not found
      #
      # Deliberately NOT wantedBy anything: enabling a template enables the bare
      # unit, and systemd will happily *start* that too -- with no instance
      # argument, so the script died on "$1: unbound variable" and left a failed
      # unit on every boot. The script tolerates a missing argument regardless.
      # -----------------------------------------------------------
      "incus-apply-notify@" = {
        description = "Notify that an Incus instance redeploy failed";
        path = with pkgs; [ coreutils gnugrep gnused libnotify ];
        script = ''
          set -uo pipefail

          # Empty when systemd starts the bare template rather than an
          # instance of it. Say so rather than dying on set -u.
          unit="''${1:-incus-apply-?}"

          # The failed unit is what the journal is filed under, so say so
          # rather than making the reader go looking.
          title="Incus redeploy failed"
          body="$unit -- journalctl -u $unit -n 50"

          for bus in /run/user/*/bus; do
            [ -S "$bus" ] || continue
            # The doubled quote escapes a shell dollar-brace from Nix
            # interpolation, which would otherwise eat it. Same shape as the
            # notify loop in modules/auto-update.nix.
            uid="''${bus#/run/user/}"
            uid="''${uid%%/*}"
            user=$(id -nu "$uid" 2>/dev/null) || continue
            sudo -u "$user" \
              DISPLAY=":0" DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
              notify-send --app-name="Incus Apply" --urgency=critical \
                "$title" "$body" >/dev/null 2>&1 || true
          done

          echo "$unit failed; see journalctl -u $unit"
        '';
      };

      # -----------------------------------------------------------
      # Reconcile all instances
      #
      # Driven by incus-reconcile.timer, below. See the comment there for why
      # this exists rather than another path unit.
      # -----------------------------------------------------------
      incus-reconcile = {
        description = "Reconcile every Incus instance against the flake";
        after = [ "network-online.target" "incus.service" ];
        wants = [ "network-online.target" ];
        requires = [ "incus.service" ];
        onFailure = [ "incus-apply-notify@%p.service" ];

        serviceConfig = {
          Type = "oneshot";
          WorkingDirectory = flakeDir;
          TimeoutStartSec = 3600;
        };

        path = [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.git
          pkgs.jq
          pkgs.nix
          config.virtualisation.incus.package
        ];

        script = "${pkgs.bash}/bin/bash ${applyScript} --all";
      };

      # -----------------------------------------------------------
      # Status
      #
      # A read-only table across every instance, so "did the hourly
      # auto-update actually redeploy what I committed?" is one command
      # rather than a journalctl scroll.
      # -----------------------------------------------------------
      incus-status = {
        description = "Show each Incus instance, its run state and its base image";
        wantedBy = [ "multi-user.target" ];
        after = [ "incus.service" ];
        path = with pkgs; [ coreutils gnugrep gnused jq config.virtualisation.incus.package ];
        script = ''
          set -euo pipefail

          printf '%-10s %-9s %-13s %s\n' INSTANCE STATE BASE-IMAGE ALIAS
          for name in ${lib.concatStringsSep " " instanceNames}; do
            # Per-instance project, matching what apply.sh uses. Reading these
            # as bare names would report every project-scoped instance as
            # missing, which is exactly the "status" question this table exists
            # to answer.
            p=${instanceProjects.${name} or ""}
            pflag=""
            qs=""
            if [[ -n $p ]]; then
              pflag="--project $p"
              qs="?project=$p"
            fi
            if ! incus info $pflag "$name" >/dev/null 2>&1; then
              printf '%-10s %-9s %-13s %s\n' "$name" "-" "-" "homelab/$name"
              continue
            fi
            state=$(incus query "/1.0/instances/$name$qs" | jq -r '.status')
            base=$(incus query "/1.0/instances/$name$qs" \
              | jq -r '.config["volatile.base_image"] // "-"' | cut -c1-12)
            printf '%-10s %-9s %-13s %s\n' "$name" "$state" "$base" "homelab/$name"
          done

          echo
          echo "images:"
          incus image list homelab --format csv 2>/dev/null \
            || echo "  (no homelab/* images yet)"
        '';
      };
    };

  # ---------------------------------------------------------------------
  # Per-instance change trigger
  #
  # Only the per-instance path units. There is deliberately no second trigger
  # keyed on the instance's secrets appearing on the host: an earlier version
  # used PathExists= for that, and it is the wrong directive here. Per
  # systemd.path(5), the monitored paths are re-checked every time the service
  # they triggered terminates -- successfully or not -- and PathExists= stays
  # true forever, so it re-fires immediately. The result was a hot loop:
  #
  #   03:40:16 reconcile -> 03:40:17 -> :18 -> :19 -> :20 -> start-limit-hit
  #
  # Five full reconciles in four seconds, each one restarting Caddy. The
  # reconcile timer below covers the same ground without depending on
  # edge-versus-level semantics I got wrong once already.
  # ---------------------------------------------------------------------
  systemd.paths = lib.mapAttrs'
    (name: _spec: {
      name = unitName name;
      value = {
        # PathChanged/PathModified rather than a `path` option: this NixOS
        # module models systemd's [Path] section as `pathConfig`, an
        # attrsOf unitOption, so each directive is a key there.
        #
        # Every file is listed individually, and every directory is listed for
        # PathChanged, because systemd.paths is NOT recursive: PathModified= on
        # a directory only gets inotify events for that directory's direct
        # children, so watching the tree root would catch a flake.nix edit and
        # silently miss hosts/caddy/default.nix. That is precisely the kind of
        # hole that goes unnoticed for a month.
        #
        # The directories cover the other half -- a file appearing or
        # disappearing changes its parent's mtime.
        pathConfig = {
          PathModified = watchFilesFor name;
          PathChanged = watchDirsFor name;
          Unit = "${unitName name}.service";
        };
        wantedBy = [ "default.target" ];
      };
    })
    instances;

  # ---------------------------------------------------------------------
  # Reconcile timer
  #
  # The safety net under the per-instance path units, and the only thing that
  # covers a secret being re-rendered on the host: /run/secrets changes when
  # the host is rebuilt, and nothing under /etc/nixos changes with it, so no
  # path unit fires and the instance would keep a stale token until the next
  # unrelated edit.
  #
  # Fifteen minutes is not a responsiveness requirement, it is a staleness bound.
  # A settled reconcile is about a second -- nix finds everything already built,
  # the fingerprint matches, zero Incus writes -- so the cost is a second of CPU
  # per instance per quarter hour.
  #
  # RandomizedDelaySec keeps fifteen instances from all deciding to reconcile at
  # the same instant. Persistent=false so a host that was off for a week does
  # not wake up and run fifteen back-to-back reconciles.
  # ---------------------------------------------------------------------
  systemd.timers.incus-reconcile = {
    description = "Periodically reconcile every Incus instance";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "15min";
      RandomizedDelaySec = "1min";
      AccuracySec = "1min";
      Persistent = false;
    };
  };
}
