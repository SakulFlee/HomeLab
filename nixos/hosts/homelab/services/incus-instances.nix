{ config, lib, pkgs, ... }:

let
  # The single source of truth for which instances exist. Same file the flake
  # exposes as `incusInstances` and incus/apply.sh reads, so the units below can
  # never drift from what apply.sh would actually do.
  instances = import ../../../incus-instances.nix;
  instanceNames = lib.attrNames instances;

  # The checkout, not a store path. incus/apply.sh and the instance specs live
  # here, and a path unit needs a real on-disk path to watch -- a store path is
  # immutable, so a unit watching one could never fire.
  repoDir = "/etc/nixos";
  flakeDir = "${repoDir}/nixos";
  applyScript = "${repoDir}/incus/apply.sh";

  # Everything that can change an instance image:
  #
  #   the flake itself      inputs, mkInstance wrapper, stateVersion
  #   hosts/<name>          that instance's OS config and Incus spec
  #   modules/              host-wide modules the image transitively imports
  #   incus-instances.nix   the registry itself
  #
  # Deliberately the whole nixos/ tree rather than a hand-picked subset. An
  # instance rebuild that turns out to be unnecessary costs a nix build that
  # finds everything already built and returns immediately; missing a real
  # dependency costs a stale image nobody notices until it matters.
  #
  # Enumerated relative to the flake root, not relative to /etc/nixos, so the
  # list is the same wherever the flake happens to be checked out -- which is
  # what makes this file evaluable off-server. The relative names are re-rooted
  # into the live checkout below.
  #
  # ../../../. is the flake root. Nix resolves a relative path literal against
  # the directory of the file it appears in, so from
  # nixos/hosts/homelab/services/ that is three levels up. "./." would enumerate
  # only this directory, and "../../." would silently stop at nixos/hosts.
  flakeRootDir = ../../../.;

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

  # Re-root a relative name into the live checkout. The empty string is the
  # tree's own root.
  reRoot = root: rel: if rel == "" then root else "${root}/${rel}";

  # The apply tooling lives outside the flake (a flake may not read paths
  # above its own root), so it cannot be enumerated here. It is one file today
  # and it is named below. The directory watch still notices a new one
  # appearing; picking it up needs a host rebuild, which is also when the
  # registry edit that justifies a third script would be committed anyway.
  #
  # builtins.pathExists matters: PathModified= against a path that does not
  # exist makes the whole path unit fail to start, and incus/ is a new
  # directory that a host which has not pulled yet does not have.
  toolingNames = [ "apply.sh" ];
  toolingFiles = builtins.filter (f: builtins.pathExists "${repoDir}/incus/${f}") toolingNames;

  watchFiles =
    map (rel: reRoot flakeDir rel) (listFilesRel flakeRootDir)
    ++ map (f: "${repoDir}/incus/${f}") toolingFiles;

  watchDirs =
    map (rel: reRoot flakeDir rel) (listDirsRel flakeRootDir)
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
          };

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

          script = "${pkgs.bash}/bin/bash ${applyScript} ${name}";
        };
      })
      instances
    // {
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
            if ! incus info "$name" >/dev/null 2>&1; then
              printf '%-10s %-9s %-13s %s\n' "$name" "-" "-" "homelab/$name"
              continue
            fi
            state=$(incus query "/1.0/instances/$name" | jq -r '.status')
            base=$(incus query "/1.0/instances/$name" \
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
          PathModified = watchFiles;
          PathChanged = watchDirs;
          Unit = "${unitName name}.service";
        };
        wantedBy = [ "default.target" ];
      };
    })
    instances;
}
