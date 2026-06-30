{ ... }: {
  imports = [
    ./jellyfin.nix
    ../../modules
  ];

  networking.hostName = "jellyfin";

  system.stateVersion = "26.05";
}
