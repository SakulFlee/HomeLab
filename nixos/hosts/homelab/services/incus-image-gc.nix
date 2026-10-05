{ config, lib, pkgs, ... }:

let
  # The checkout, not a store path, for the same reason incus-reconcile uses one:
  # a unit that watches or execs a store path is watching something immutable.
  repoDir = "/etc/nixos";
  gcScript = "${repoDir}/incus/incus-image-gc.sh";
in
{
  systemd.services.incus-image-gc = {
    description = "Delete Incus images the reconciler left unreferenced";

    # Ordered after the Nix garbage collector so the two maintenance jobs do not
    # overlap. nix-gc reclaims store paths and incus-image-gc reclaims images, and
    # there is no reason for both to be saturating the disk at once.
    #
    # `wantedBy` rather than only `after`, because `after` alone would never start
    # this unit: it orders things that are already in the same transaction, and
    # nothing else pulls it in. wantedBy puts it in nix-gc.service's transaction,
    # after then makes the order real. (A `WantedBy=` on a *service* schedules
    # nothing -- that is what the separate timer below is for.)
    wantedBy = [ "nix-gc.service" ];
    after = [ "nix-gc.service" ];
    requires = [ "incus.service" ];
    wants = [ "incus.service" ];

    serviceConfig = {
      Type = "oneshot";
      # Garbage collection must not be able to take a reconcile with it, and must
      # not hold the boot sequence open if Incus is unhappy.
      TimeoutStartSec = 1800;
    };

    path = with pkgs; [
      bash
      coreutils
      gnugrep
      jq
      config.virtualisation.incus.package
    ];

    script = "${pkgs.bash}/bin/bash ${gcScript}";
  };

  # Weekly, and chained to nix-gc rather than given its own opinion about when
  # maintenance happens.
  #
  # There is no separate OnCalendar here on purpose. The cadence comes from
  # nix-gc.timer, which nixos/modules/gc.nix sets to `weekly`. A second timer
  # would mean two schedules to keep in agreement, and the retention window the
  # GC actually offers is measured in observations rather than in days anyway --
  # see the header of incus-image-gc.sh. Setting this to weekly as well would
  # only be a second place for the two to drift.
  #
  # Persistent=true, so a host that was off when the window passed still collects
  # once it is back instead of skipping a week. nix-gc.timer already has that.
  systemd.timers.incus-image-gc = {
    description = "Periodically delete unreferenced Incus images";
    timerConfig = {
      OnBootSec = "30min";
      OnUnitInactiveSec = "7d";
      Persistent = true;
    };
  };
}