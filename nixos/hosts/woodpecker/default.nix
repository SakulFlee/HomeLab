{ ... }: {
  imports = [
    ./woodpecker-server.nix
    ./woodpecker-agent.nix
    ./postgres.nix
    ../../modules
  ];

  networking.hostName = "woodpecker";

  system.stateVersion = "26.05";
}
