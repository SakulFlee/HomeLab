{ ... }: {
  # Daily, not weekly.
  #
  # The host is now also the Nix builder for the NixOS-Config flake-lock
  # gate. That job builds a fresh Dendra closure daily with `--no-link`; the
  # outputs are unrooted, but they are large. A weekly 7-day window would
  # hold a week of them. Daily/3d matches the NixOS-Config host's own policy
  # and keeps the shared store bounded.
  #
  # Two separate knobs, and it is worth being precise about which does what,
  # because the obvious reading of the option below is wrong:
  #
  #   dates              -> OnCalendar. When the sweep runs. Nothing about
  #                         retention depends on this.
  #   --delete-older-than How many recent NixOS configurations stay rollback-
  #                         able. From the Nix manual:
  #
  #                           "Delete all generations of profiles older than the
  #                            specified amount (except for the generations that
  #                            were active at that point in time)."
  #
  #                         and, on the same page: "Deleting previous
  #                         configurations makes rollbacks to them impossible."
  #
  # A generation is a garbage-collection root, so dropping one releases its
  # closure. The store paths themselves have no age gate: plain
  # nix-collect-garbage deletes everything unreachable on every run.
  #
  # Retention therefore equals the interval, which is the point of running
  # daily: the window you keep is the window between sweeps.
  #
  # `-d` is deliberately gone. It means "delete ALL old generations", which if
  # it took effect would make any age threshold meaningless, and its
  # interaction with --delete-older-than could not be measured on this box --
  # every variant of --dry-run reported an identical "731 store paths would be
  # deleted". One flag, one meaning, nothing to reason about.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 3d";
  };
}