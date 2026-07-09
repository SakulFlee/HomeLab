{ ... }: {
  imports = [
    ./palworld.nix
    ../../modules
  ];

  networking.hostName = "palworld";

  system.stateVersion = "26.05";
}
