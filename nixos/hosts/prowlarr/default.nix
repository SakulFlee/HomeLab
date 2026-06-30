{ ... }: {
  imports = [
    ./prowlarr.nix
    ../../modules
  ];

  networking.hostName = "prowlarr";

  system.stateVersion = "26.05";
}
