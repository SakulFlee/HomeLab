{ ... }: {
  imports = [
    ./sonarr.nix
    ../../modules
  ];

  networking.hostName = "sonarr";

  system.stateVersion = "26.05";
}
