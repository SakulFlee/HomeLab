{ config, ... }:

{
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-generations";
  };
  nix.extraOptions = "auto-optimise-store = true";
}
