{ ... }: {
  imports = [
    ./hytale.nix
    ../../modules
  ];

  networking.hostName = "hytale";

  system.stateVersion = "26.05";
}
