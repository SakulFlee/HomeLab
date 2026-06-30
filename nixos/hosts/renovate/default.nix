{ ... }: {
  imports = [
    ./renovate.nix
    ../../modules
  ];

  networking.hostName = "renovate";

  system.stateVersion = "26.05";
}
