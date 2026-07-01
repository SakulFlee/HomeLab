{ ... }: {
  imports = [
    ./qbittorrent.nix
  ];

  networking.hostName = "qbittorrent";

  system.stateVersion = "26.05";
}
