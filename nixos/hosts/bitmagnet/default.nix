{ ... }: {
  imports = [
    ./bitmagnet.nix
  ];

  networking.hostName = "bitmagnet";

  system.stateVersion = "26.05";
}
