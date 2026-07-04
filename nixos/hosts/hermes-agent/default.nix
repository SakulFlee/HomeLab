{ ... }: {
  imports = [
    ./hermes-agent.nix
    ../../modules
  ];

  networking.hostName = "hermes-agent";

  system.stateVersion = "26.05";
}
