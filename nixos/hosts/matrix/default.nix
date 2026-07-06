{ ... }: {
  imports = [
    ./tuwunel.nix
    ../../modules
  ];

  networking.hostName = "matrix";

  system.stateVersion = "26.05";
}
