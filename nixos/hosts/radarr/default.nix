{ ... }: {
  imports = [
    ./radarr.nix
    ../../modules
  ];

  networking.hostName = "radarr";

  system.stateVersion = "26.05";
}
