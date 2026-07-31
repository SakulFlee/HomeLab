{ ... }: {
  # Automatically cleanup (garbage collect -> gc) any nix-envs older than 7 days.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-odler-than 3d";
  };
}
