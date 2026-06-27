{ ... }: {
  imports = [
    ./forgejo.nix
    ./postgres.nix
    ../../modules
  ];

  networking.hostName = "forgejo";

  system.stateVersion = "26.05";
}
