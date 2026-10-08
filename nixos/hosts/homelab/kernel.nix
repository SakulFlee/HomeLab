{ lib, pkgs, ... }: {
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Containers share the host kernel, so these are the numbers that decide
  # whether Syncthing's inotify watcher (fsWatcherEnabled, set per folder in
  # hosts/syncthing/default.nix) can watch a large tree. The kernel default
  # per-UID budget is easily exceeded by a personal folder with many
  # directories -- and the failure is a log line and a silent fallback to
  # periodic rescans, not a startup error, so it would go unnoticed.
  #
  # Every container's root shares one host UID under Incus's non-isolated idmap,
  # so they share this budget; raising it once here covers the hub and anything
  # reading the same volumes.
  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 524288;
    "fs.inotify.max_user_instances" = 1024;
  };
}
