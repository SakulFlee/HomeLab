{ ... }: {
  imports = [
    ./syncthing.nix
    ../../modules
  ];

  networking.hostName = "syncthing";

  system.stateVersion = "26.05";
}
