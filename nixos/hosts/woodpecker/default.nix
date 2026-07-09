{ ... }: {
  imports = [
    ./woodpecker-server.nix
    ./postgres.nix
    ../../modules
  ];

  networking.hostName = "woodpecker";

  system.stateVersion = "26.05";
}
