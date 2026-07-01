{ ... }: {
  imports = [
    ./qbittorrent.nix
    ../../modules
  ];

  networking.hostName = "qbittorrent";

  system.stateVersion = "26.05";
}
